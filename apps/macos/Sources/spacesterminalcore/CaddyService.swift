import Foundation

#if os(macOS)
    /// Manages the bundled Caddy binary that reverse-proxies `<service>.<workspace-slug>.localhost`
    /// hosts to each workspace's dynamically assigned local port. Mirrors `TerminalService`: locate
    /// the binary, spawn it detached, reload its config gracefully, and stop it on the SIGTERM→SIGKILL
    /// ladder. Caddy runs only on the Mac (where the browser is), so this is macOS-only.
    ///
    /// The config and admin endpoint live under the active profile's runtime directory so dev and
    /// installed profiles never clash. The admin endpoint is a unix socket (no TCP exposure), and
    /// reloads are performed by the bundled `caddy reload` CLI rather than a hand-written
    /// HTTP-over-unix client.
    public enum CaddyService {
        public static let executableEnvironmentVariable = "SPACES_CADDY_EXECUTABLE"

        /// Path to the generated Caddy config for the active profile.
        public static func configFilePath() throws -> String { try (runtimeDirectory() as NSString).appendingPathComponent("caddy.json") }

        /// Unix socket the Caddy admin API listens on for the active profile. Callers must embed this
        /// in the generated config (admin.listen) so it matches the address used for reloads.
        public static func adminSocketPath() throws -> String { try (runtimeDirectory() as NSString).appendingPathComponent("caddy-admin.sock") }

        /// Client-owned route registry read by the local macOS daemon when reconciling Caddy.
        public static func routeRegistryPath() throws -> String { try (runtimeDirectory() as NSString).appendingPathComponent("caddy-routes.json") }

        /// Ensures Caddy is running with the given config. If it is already running, the config is
        /// reloaded gracefully; otherwise it is started fresh. Returns true when a new process was
        /// launched.
        @discardableResult public static func ensureRunning(configJSON: Data, timeout: TimeInterval = 5) throws -> Bool {
            let configPath = try configFilePath()
            let socketPath = try adminSocketPath()
            try writeConfig(configJSON, to: configPath)

            if FileManager.default.fileExists(atPath: socketPath) {
                if runReload(configPath: configPath, socketPath: socketPath, timeout: 2) { return false }
                if adminSocketHasOwner(socketPath) { throw CaddyServiceError.reloadFailed(configPath) }
                try? FileManager.default.removeItem(atPath: socketPath)
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

        /// Reloads a running Caddy with the given config. Throws if Caddy is not running or the reload
        /// fails; callers can recover by calling `ensureRunning`.
        public static func reload(configJSON: Data, timeout: TimeInterval = 5) throws {
            let configPath = try configFilePath()
            let socketPath = try adminSocketPath()
            try writeConfig(configJSON, to: configPath)
            guard runReload(configPath: configPath, socketPath: socketPath, timeout: timeout) else {
                throw CaddyServiceError.reloadFailed(configPath)
            }
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

        private static func runReload(configPath: String, socketPath: String, timeout: TimeInterval) -> Bool {
            guard let executableURL = try? resolveExecutableURL() else { return false }
            return runCaddy(
                executableURL: executableURL, arguments: ["reload", "--config", configPath, "--address", "unix//\(socketPath)"], timeout: timeout)
                == 0
        }

        /// Runs a short-lived Caddy CLI invocation and returns its exit status, or nil on launch failure
        /// or timeout. Reloads/stops are infrequent (lifecycle events) so a blocking child is fine.
        @discardableResult private static func runCaddy(executableURL: URL, arguments: [String], timeout: TimeInterval) -> Int32? {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning {
                process.terminate()
                return nil
            }
            return process.terminationStatus
        }

        private static func terminateProcessesOwningSocket(_ socketPath: String, timeout: TimeInterval) {
            let pids = serviceProcessIDsOwningSocket(socketPath).filter { $0 > 0 && $0 != getpid() }
            guard !pids.isEmpty else { return }
            for pid in pids { kill(pid, SIGTERM) }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if pids.allSatisfy({ !isProcessAlive(pid: Int($0)) }) { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            for pid in pids where isProcessAlive(pid: Int(pid)) { kill(pid, SIGKILL) }
        }

        private static func serviceProcessIDsOwningSocket(_ socketPath: String) -> Set<pid_t> {
            let candidates = ["/usr/sbin/lsof", "/usr/bin/lsof"]
            guard let executablePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["-nP", "-U"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch { return [] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else { return [] }
            return TerminalService.parseSocketOwnerProcessIDs(String(decoding: data, as: UTF8.self), socketPath: socketPath)
        }

        private static func adminSocketHasOwner(_ socketPath: String) -> Bool { !serviceProcessIDsOwningSocket(socketPath).isEmpty }

        static func resolveExecutableURL(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default)
            throws -> URL
        {
            let currentExecutablePath = environment["_"] ?? Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
            let currentExecutableDirectory = URL(fileURLWithPath: currentExecutablePath).deletingLastPathComponent()
            let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            let bundledResourceDirectory = currentExecutableDirectory.deletingLastPathComponent().appendingPathComponent(
                "Resources", isDirectory: true)
            let candidates = [
                environment[executableEnvironmentVariable],
                currentExecutableDirectory.appendingPathComponent("spaces-caddy", isDirectory: false).path(percentEncoded: false),
                Bundle.main.resourceURL?.appendingPathComponent("caddy", isDirectory: false).path(percentEncoded: false),
                bundledResourceDirectory.appendingPathComponent("caddy", isDirectory: false).path(percentEncoded: false),
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

    public enum CaddyServiceError: LocalizedError {
        case executableNotFound
        case startupTimedOut(String)
        case reloadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .executableNotFound: "The caddy executable is required to route workspace service URLs."
            case .startupTimedOut(let path): "Timed out waiting for caddy to start from \(path)."
            case .reloadFailed(let path): "Failed to reload caddy with config at \(path)."
            }
        }
    }
#endif
