import Foundation

#if os(macOS)
    import Darwin

    /// Manages the bundled Caddy binary that reverse-proxies `<service>.<workspace-slug>.localhost`
    /// hosts to each workspace's dynamically assigned local port. Mirrors `TerminalService`: locate
    /// the binary, spawn it detached, reload its config gracefully, and stop it on the SIGTERM→SIGKILL
    /// ladder. Caddy runs only on the Mac (where the browser is), so this is macOS-only.
    ///
    /// The config lives under the active profile's runtime directory so dev and installed profiles
    /// never clash; the admin endpoint is a unix socket under the shared `SpacesSocketPaths` root
    /// (no TCP exposure), and reloads are performed by the bundled `caddy reload` CLI rather than a
    /// hand-written HTTP-over-unix client.
    public enum CaddyService {
        public static let executableEnvironmentVariable = "SPACES_CADDY_EXECUTABLE"

        /// Path to the generated Caddy config for the active profile.
        public static func configFilePath() throws -> String { try (runtimeDirectory() as NSString).appendingPathComponent("caddy.json") }

        /// Unix socket the Caddy admin API listens on for the active profile. Callers must embed this
        /// in the generated config (admin.listen) so it matches the address used for reloads.
        ///
        /// Lives under the shared `SpacesSocketPaths.secureSocketRoot()` rather than the profile
        /// runtime directory (see that type for why). The filename is a stable hash of the runtime
        /// directory (mirroring `TerminalServicePaths`) so each profile still gets its own distinct
        /// admin socket within the shared root.
        public static func adminSocketPath() throws -> String {
            let socketRoot = try SpacesSocketPaths.secureSocketRoot()
            let hash = SpacesProfile.shortStableHash(SpacesProfile.canonicalPath(try runtimeDirectory()))
            return socketRoot.appendingPathComponent("admin-\(hash).sock", isDirectory: false).path
        }

        /// Client-owned route registry read by the local macOS daemon when reconciling Caddy.
        public static func routeRegistryPath() throws -> String { try (runtimeDirectory() as NSString).appendingPathComponent("caddy-routes.json") }

        /// Ensures Caddy is running with the given config. If it is already running, the config is
        /// reloaded gracefully; otherwise it is started fresh. Returns true when a new process was
        /// launched.
        ///
        /// A reload that a confirmed-live Caddy rejects (bad config) or never answers (wedged) does not
        /// throw: a live Caddy that refuses the new config would otherwise keep serving the previous
        /// route table indefinitely, with nothing to prompt a retry until some later, unrelated
        /// reconcile pass happens to succeed. Instead this stops that instance (the same ladder `stop()`
        /// uses) and falls through to the fresh-start path below with the config already written, so
        /// routes recover within this call. The original reload failure is not lost: it is written to
        /// stderr (`CaddyServiceError.reloadFailed`'s description carries the child's exit status and a
        /// bounded tail of its stderr) so the reason is diagnosable even though recovery means nothing
        /// is thrown. Only a fresh start that itself fails to come up still throws, unchanged from before.
        @discardableResult public static func ensureRunning(configJSON: Data, timeout: TimeInterval = 5) throws -> Bool {
            let configPath = try configFilePath()
            let socketPath = try adminSocketPath()
            try writeConfig(configJSON, to: configPath)

            if FileManager.default.fileExists(atPath: socketPath) {
                let reloadResult = runReload(configPath: configPath, socketPath: socketPath, timeout: 2)
                if reloadResult.exitStatus == 0 { return false }
                // The owner probe decides whether it is safe to unlink the socket; a wrong "no
                // owner" answer destroys a live Caddy's admin socket. It therefore gets its own
                // generous bound (like the reload above) instead of the caller's startup budget,
                // which tests legitimately set near zero.
                if adminSocketHasOwner(socketPath, timeout: 10) {
                    logReloadFailureRecovery(configPath: configPath, result: reloadResult)
                    stop(timeout: timeout)
                } else {
                    try? FileManager.default.removeItem(atPath: socketPath)
                }
            }

            let executableURL = try resolveExecutableURL()
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["run", "--config", configPath]
            process.environment = ProcessInfo.processInfo.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: socketPath) { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw CaddyServiceError.startupTimedOut(executableURL.path)
        }

        /// Gracefully stops the Caddy process for the active profile.
        public static func stop(timeout: TimeInterval = 5) {
            guard let socketPath = try? adminSocketPath() else { return }
            if let executableURL = try? resolveExecutableURL() {
                _ = runCaddy(executableURL: executableURL, arguments: ["stop", "--address", "unix//\(socketPath)"], timeout: min(timeout, 2))
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if !FileManager.default.fileExists(atPath: socketPath) { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            terminateProcessesOwningSocket(socketPath, timeout: timeout)
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        static func runtimeDirectory() throws -> String { try SpacesProfile.current().runtimeDirectory }

        private static func writeConfig(_ configJSON: Data, to path: String) throws {
            try configJSON.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        private static func runReload(configPath: String, socketPath: String, timeout: TimeInterval) -> CaddyProcessResult {
            guard let executableURL = try? resolveExecutableURL() else { return CaddyProcessResult(exitStatus: nil, stderr: "") }
            return runCaddy(
                executableURL: executableURL, arguments: ["reload", "--config", configPath, "--address", "unix//\(socketPath)"], timeout: timeout)
        }

        /// Writes the recovered-from reload failure to stderr so the daemon log carries why Caddy
        /// refused the new config, even though `ensureRunning` does not throw for this case (see its
        /// doc comment). Reuses `CaddyServiceError.reloadFailed`'s description instead of formatting the
        /// exit status and stderr text a second time.
        private static func logReloadFailureRecovery(configPath: String, result: CaddyProcessResult) {
            let error = CaddyServiceError.reloadFailed(configPath: configPath, exitStatus: result.exitStatus, stderr: result.stderr)
            FileHandle.standardError.write(Data("caddy: \(error.localizedDescription); restarting to recover routes.\n".utf8))
        }

        /// Last N bytes of a reload's stderr kept for diagnostics. Bounded so a runaway or chatty
        /// Caddy build cannot balloon the daemon's log line; a rejected config's error is always near
        /// the end of its output.
        private static let stderrCaptureLimitBytes = 2048

        /// Runs a short-lived Caddy CLI invocation and returns its exit status (nil on launch failure or
        /// timeout) and a bounded tail of its stderr. Reloads/stops are infrequent (lifecycle events) so
        /// a blocking child is fine.
        @discardableResult private static func runCaddy(executableURL: URL, arguments: [String], timeout: TimeInterval) -> CaddyProcessResult {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errorPipe = Pipe()
            process.standardError = errorPipe
            do { try process.run() } catch { return CaddyProcessResult(exitStatus: nil, stderr: "") }

            // Mirrors `TerminalService.capturedStandardOutput`'s watchdog-plus-drain shape: the pipe must
            // be drained before waiting on exit (a chatty child can fill the kernel's 64KB pipe buffer
            // and block forever on a reader that never shows up), and the watchdog SIGKILLs a child that
            // outlives `timeout` so this never blocks past its caller's budget.
            let timedOutLock = NSLock()
            var timedOut = false
            let watchdog = DispatchWorkItem {
                guard process.isRunning else { return }
                timedOutLock.lock()
                timedOut = true
                timedOutLock.unlock()
                kill(process.processIdentifier, SIGKILL)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()

            timedOutLock.lock()
            let didTimeOut = timedOut
            timedOutLock.unlock()
            let stderrTail = stderrData.suffix(stderrCaptureLimitBytes)
            let stderrText = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return CaddyProcessResult(exitStatus: didTimeOut ? nil : process.terminationStatus, stderr: stderrText)
        }

        private static func terminateProcessesOwningSocket(_ socketPath: String, timeout: TimeInterval) {
            // An indeterminate sweep (nil) leaves nothing to kill; this stage is best-effort and
            // stop() removes the socket file regardless.
            let pids = (serviceProcessIDsOwningSocket(socketPath, timeout: timeout) ?? []).filter { $0 > 0 && $0 != getpid() }
            guard !pids.isEmpty else { return }
            for pid in pids { kill(pid, SIGTERM) }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if pids.allSatisfy({ !isProcessAlive(pid: Int($0)) }) { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            for pid in pids where isProcessAlive(pid: Int(pid)) { kill(pid, SIGKILL) }
        }

        private static func serviceProcessIDsOwningSocket(_ socketPath: String, timeout: TimeInterval) -> Set<pid_t>? {
            TerminalService.serviceProcessIDsOwningSocket(socketPath, timeout: timeout)
        }

        private static func adminSocketHasOwner(_ socketPath: String, timeout: TimeInterval) -> Bool {
            // An indeterminate sweep must read as "owner present": ensureRunning unlinks the socket
            // on a "no owner" answer, and a wrong unlink orphans a live Caddy's admin socket.
            guard let owners = serviceProcessIDsOwningSocket(socketPath, timeout: timeout) else { return true }
            return !owners.isEmpty
        }

        /// True when a live Caddy owns the profile's admin socket. Unlike checking for the generated
        /// config file or the socket file on disk (both of which survive a crash or `stop()`), this
        /// connects to the admin socket: a graceful `stop()` removes the socket so `connect` fails with
        /// ENOENT, and a crash leaves an unowned socket whose `connect` fails with ECONNREFUSED. Callers
        /// use this to distinguish a Caddy that is actually serving routes from a stale on-disk config.
        public static func isRunning() -> Bool {
            guard let socketPath = try? adminSocketPath() else { return false }
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let utf8Path = socketPath.utf8CString
            guard utf8Path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
            withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
                utf8Path.withUnsafeBufferPointer { buffer in if let baseAddress = buffer.baseAddress { memcpy(pointer, baseAddress, buffer.count) } }
            }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            } == 0
        }

        static func resolveExecutableURL(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default)
            throws -> URL
        {
            let currentExecutablePath = environment["_"] ?? Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
            let currentExecutableURL = URL(fileURLWithPath: currentExecutablePath)
            let currentExecutableDirectory = currentExecutableURL.deletingLastPathComponent()
            let resolvedCurrentExecutableDirectory = currentExecutableURL.resolvingSymlinksInPath().deletingLastPathComponent()
            let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            let bundledResourceDirectory = currentExecutableDirectory.deletingLastPathComponent().appendingPathComponent(
                "Resources", isDirectory: true)
            let candidates = [
                environment[executableEnvironmentVariable],
                currentExecutableDirectory.appendingPathComponent("spaces-caddy", isDirectory: false).path(percentEncoded: false),
                resolvedCurrentExecutableDirectory.appendingPathComponent("caddy", isDirectory: false).path(percentEncoded: false),
                Bundle.main.resourceURL?.appendingPathComponent("caddy", isDirectory: false).path(percentEncoded: false),
                bundledResourceDirectory.appendingPathComponent("caddy", isDirectory: false).path(percentEncoded: false),
                SpacesBinaryLayout.systemLinkURL(for: .spacesCaddy).path,
                currentDirectory.appendingPathComponent("apps/macos/.local/caddy/caddy", isDirectory: false).path(percentEncoded: false),
                currentDirectory.appendingPathComponent(".local/caddy/caddy", isDirectory: false).path(percentEncoded: false),
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

            for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate, isDirectory: false)
            }
            throw CaddyServiceError.executableNotFound
        }

        private static func isProcessAlive(pid: Int) -> Bool {
            guard pid > 0 else { return false }
            if kill(pid_t(pid), 0) == 0 { return true }
            return errno == EPERM
        }
    }

    /// Outcome of a short-lived `caddy` CLI invocation (`reload`, `stop`). `exitStatus` is nil when the
    /// process never launched or was killed for outliving its timeout; `stderr` is a bounded tail (see
    /// `CaddyService.stderrCaptureLimitBytes`), empty when nothing was captured.
    private struct CaddyProcessResult {
        let exitStatus: Int32?
        let stderr: String
    }

    public enum CaddyServiceError: LocalizedError {
        case executableNotFound
        case startupTimedOut(String)
        /// A `caddy reload` invocation against a confirmed-live Caddy failed. `exitStatus` is nil when
        /// the child never launched or was killed for outliving its timeout. `ensureRunning` recovers
        /// from this itself (see its doc comment) rather than throwing it, so in practice this case is
        /// constructed only to format the recovery's diagnostic log line.
        case reloadFailed(configPath: String, exitStatus: Int32?, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .executableNotFound: return "The caddy executable is required to route workspace service URLs."
            case .startupTimedOut(let path): return "Timed out waiting for caddy to start from \(path)."
            case .reloadFailed(let configPath, let exitStatus, let stderr):
                let statusText = exitStatus.map { "exit \($0)" } ?? "timed out"
                let stderrSuffix = stderr.isEmpty ? "" : ": \(stderr)"
                return "Failed to reload caddy with config at \(configPath) (\(statusText))\(stderrSuffix)"
            }
        }
    }
#endif
