import Foundation

#if os(macOS)
    public enum TerminalService {
        public static func ping(timeout: TimeInterval = 2) throws {
            let response = try pingResponse(timeout: timeout)
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
        }

        public static func createSession(_ launchConfiguration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary {
            if shouldUseXCTestCompatibilityBackend() { return try createXCTestCompatibilitySession(launchConfiguration) }
            let startedAt = Date()
            let ensureStartedAt = Date()
            let launchedService = try ensureRunning()
            let ensureElapsedMS = TerminalPerformance.elapsedMS(since: ensureStartedAt)
            let socketPath = try TerminalServicePaths.socketPath()
            let requestStartedAt = Date()
            let requestTimeout = createSessionRequestTimeout()
            let rpcTimeout = min(requestTimeout, createSessionRPCResponseTimeout())
            let response: TerminalServiceResponse
            do {
                response = try TerminalServiceClient.send(
                    request: TerminalServiceRequest(command: "create", launchConfiguration: launchConfiguration), socketPath: socketPath,
                    timeout: rpcTimeout)
            } catch {
                if let recovered = waitForCreatedSessionSummary(launchConfiguration, timeout: requestTimeout) {
                    TerminalPerformance.logMetric(
                        "terminal_service_create_session", target: "session=\(launchConfiguration.sessionID)",
                        elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                        detail:
                            "service_launch=\(launchedService ? 1 : 0) ensure_running_ms=\(ensureElapsedMS) rpc_ms=\(TerminalPerformance.elapsedMS(since: requestStartedAt)) recovered=1 error=\(String(describing: error)) state=\(recovered.state.rawValue)"
                    )
                    return recovered
                }
                throw error
            }
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
            guard let session = response.session else {
                throw TerminalServiceError.requestFailed("Terminal service did not return a session summary.")
            }
            TerminalPerformance.logMetric(
                "terminal_service_create_session", target: "session=\(launchConfiguration.sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                detail:
                    "service_launch=\(launchedService ? 1 : 0) ensure_running_ms=\(ensureElapsedMS) rpc_ms=\(TerminalPerformance.elapsedMS(since: requestStartedAt)) state=\(session.state.rawValue)"
            )
            return session
        }

        public static func terminateSession(id sessionID: String) throws {
            if shouldUseXCTestCompatibilityBackend() {
                try terminateXCTestCompatibilitySession(id: sessionID)
                return
            }
            try ensureRunning()
            let socketPath = try TerminalServicePaths.socketPath()
            let response = try TerminalServiceClient.send(
                request: TerminalServiceRequest(command: "terminate", sessionID: sessionID), socketPath: socketPath, timeout: 10)
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
        }

        public static func listSessions() throws -> [TerminalServiceSessionSummary] {
            if shouldUseXCTestCompatibilityBackend() { return try listXCTestCompatibilitySessions() }
            let socketPath = try TerminalServicePaths.socketPath()
            guard FileManager.default.fileExists(atPath: socketPath) else { return [] }
            let response = try TerminalServiceClient.send(request: TerminalServiceRequest(command: "list"), socketPath: socketPath, timeout: 5)
            guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
            return response.sessions ?? []
        }

        @discardableResult public static func ensureRunning(timeout: TimeInterval = 5) throws -> Bool {
            let startedAt = Date()
            let socketPath = try TerminalServicePaths.socketPath()
            if FileManager.default.fileExists(atPath: socketPath), (try? ping(timeout: 1)) != nil {
                TerminalPerformance.logMetric(
                    "terminal_service_ensure_running", target: "socket=\(socketPath)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                    success: true, detail: "launched=0")
                return false
            }

            let executableURL = try resolveExecutableURL()
            let process = Process()
            process.executableURL = executableURL
            process.environment = ProcessInfo.processInfo.environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: socketPath), (try? ping(timeout: 1)) != nil {
                    TerminalPerformance.logMetric(
                        "terminal_service_ensure_running", target: "socket=\(socketPath)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: true, detail: "launched=1 pid=\(process.processIdentifier)")
                    return true
                }
                Thread.sleep(forTimeInterval: 0.05)
            }

            TerminalPerformance.logMetric(
                "terminal_service_ensure_running", target: "socket=\(socketPath)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                success: false, detail: "launched=1 pid=\(process.processIdentifier)")
            throw TerminalServiceError.serviceStartupTimedOut(executableURL.path)
        }

        @discardableResult public static func relaunch(timeout: TimeInterval = 5) throws -> Bool {
            let socketPath = try TerminalServicePaths.socketPath()
            if FileManager.default.fileExists(atPath: socketPath) {
                stopExistingService(socketPath: socketPath, timeout: min(max(timeout / 2, 0.5), 2))
            }
            try? FileManager.default.removeItem(atPath: socketPath)
            return try ensureRunning(timeout: timeout)
        }

        private static func pingResponse(timeout: TimeInterval = 2) throws -> TerminalServiceResponse {
            let socketPath = try TerminalServicePaths.socketPath()
            return try TerminalServiceClient.send(request: TerminalServiceRequest(command: "ping"), socketPath: socketPath, timeout: timeout)
        }

        private static func stopExistingService(socketPath: String, timeout: TimeInterval) {
            var candidatePIDs = Set<pid_t>()
            if let response = try? pingResponse(timeout: min(timeout, 1)), let servicePID = response.servicePID {
                candidatePIDs.insert(pid_t(servicePID))
            }

            if let response = try? TerminalServiceClient.send(
                request: TerminalServiceRequest(command: "shutdown"), socketPath: socketPath, timeout: min(timeout, 1))
            {
                if let servicePID = response.servicePID { candidatePIDs.insert(pid_t(servicePID)) }
                if response.ok, waitForServiceExit(socketPath: socketPath, candidatePIDs: candidatePIDs, timeout: timeout) { return }
            }

            if candidatePIDs.isEmpty { candidatePIDs.formUnion(serviceProcessIDsOwningSocket(socketPath)) }
            terminateServiceProcesses(candidatePIDs, timeout: timeout)
        }

        private static func terminateServiceProcesses(_ pids: Set<pid_t>, timeout: TimeInterval) {
            let targetPIDs = pids.filter { $0 > 0 && $0 != getpid() }
            guard !targetPIDs.isEmpty else { return }

            for pid in targetPIDs { kill(pid, SIGTERM) }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if targetPIDs.allSatisfy({ !isProcessAlive(pid: Int($0)) }) { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            for pid in targetPIDs where isProcessAlive(pid: Int(pid)) { kill(pid, SIGKILL) }
        }

        private static func waitForServiceExit(socketPath: String, candidatePIDs: Set<pid_t>, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let livePIDs = candidatePIDs.filter { isProcessAlive(pid: Int($0)) }
                let canPing = FileManager.default.fileExists(atPath: socketPath) && ((try? pingResponse(timeout: 0.2)) != nil)
                if livePIDs.isEmpty && !canPing { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return false
        }

        private static func serviceProcessIDsOwningSocket(_ socketPath: String) -> Set<pid_t> {
            let candidates = ["/usr/sbin/lsof", "/usr/bin/lsof"]
            guard let executablePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["-t", "-U", socketPath]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch { return [] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else { return [] }
            return parseProcessIDs(String(decoding: data, as: UTF8.self))
        }

        static func parseProcessIDs(_ output: String) -> Set<pid_t> {
            let processIDs: [pid_t] = output.split(whereSeparator: \.isWhitespace).compactMap { token in
                guard let processID = Int32(token, radix: 10) else { return nil }
                return processID
            }
            return Set(processIDs)
        }

        private static func shouldUseXCTestCompatibilityBackend() -> Bool {
            isRunningUnderXCTest() && ProcessInfo.processInfo.environment["SPACES_TERMINAL_SERVICE_EXECUTABLE"] == nil
        }

        static func createSessionRequestTimeout(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
            positiveTimeout(environment["SPACES_TERMINAL_SERVICE_CREATE_TIMEOUT"], defaultValue: 30)
        }

        static func createSessionRPCResponseTimeout(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
            positiveTimeout(environment["SPACES_TERMINAL_SERVICE_CREATE_RPC_TIMEOUT"], defaultValue: 2)
        }

        private static func positiveTimeout(_ rawValue: String?, defaultValue: TimeInterval) -> TimeInterval {
            guard let rawValue, let value = TimeInterval(rawValue), value > 0 else { return defaultValue }
            return value
        }

        private static func waitForCreatedSessionSummary(_ launchConfiguration: TerminalSessionLaunchConfiguration, timeout: TimeInterval)
            -> TerminalServiceSessionSummary?
        {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if let summary = try? sessionSummaryIfLive(for: launchConfiguration) { return summary }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
            return nil
        }

        private static func sessionSummaryIfLive(for launchConfiguration: TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary?
        {
            let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
            guard FileManager.default.fileExists(atPath: paths.controlSocketPath), FileManager.default.fileExists(atPath: paths.statePath) else {
                return nil
            }
            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            guard runtimeState.state == .starting || runtimeState.state == .running else { return nil }
            guard isProcessAlive(pid: Int(runtimeState.servicePID)) else { return nil }
            return TerminalServiceSessionSummary(
                id: launchConfiguration.sessionID, title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, backend: launchConfiguration.backend,
                lifetimePolicy: launchConfiguration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
                childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
        }

        private static func createXCTestCompatibilitySession(_ launchConfiguration: TerminalSessionLaunchConfiguration) throws
            -> TerminalServiceSessionSummary
        {
            let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
            FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
            FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
            FileManager.default.createFile(atPath: paths.controlSocketPath, contents: nil)

            let runtimeState =
                (try? TerminalSessionPersistence.readRuntimeState(paths: paths))
                ?? TerminalSessionRuntimeState(
                    sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: nil,
                    state: .running, updatedAt: ISO8601DateFormatter().string(from: Date()), title: launchConfiguration.title,
                    workingDirectory: launchConfiguration.workingDirectory)
            try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
            return TerminalServiceSessionSummary(
                id: launchConfiguration.sessionID, title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, backend: launchConfiguration.backend,
                lifetimePolicy: launchConfiguration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
                childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
        }

        private static func terminateXCTestCompatibilitySession(id sessionID: String) throws {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            guard let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths) else { return }
            let now = ISO8601DateFormatter().string(from: Date())
            let runtimeState =
                (try? TerminalSessionPersistence.readRuntimeState(paths: paths))
                ?? TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: nil, state: .exited, updatedAt: now,
                    exitedAt: now, title: launchConfiguration.title, workingDirectory: launchConfiguration.workingDirectory)
            let exitedState = TerminalSessionRuntimeState(
                sessionID: sessionID, backend: runtimeState.backend, servicePID: runtimeState.servicePID, childPID: runtimeState.childPID,
                state: .exited, updatedAt: now, exitedAt: now, title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, columns: runtimeState.columns,
                rows: runtimeState.rows)
            try TerminalSessionPersistence.writeRuntimeState(exitedState, paths: paths)
            try? FileManager.default.removeItem(atPath: paths.controlSocketPath)
        }

        private static func listXCTestCompatibilitySessions() throws -> [TerminalServiceSessionSummary] {
            try TerminalSessionPersistence.listKnownSessions().compactMap { launchConfiguration in
                let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
                guard FileManager.default.fileExists(atPath: paths.controlSocketPath), FileManager.default.fileExists(atPath: paths.statePath) else {
                    return nil
                }
                guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths) else { return nil }
                guard runtimeState.state == .starting || runtimeState.state == .running else { return nil }
                guard isProcessAlive(pid: Int(runtimeState.servicePID)) else { return nil }
                return TerminalServiceSessionSummary(
                    id: launchConfiguration.sessionID, title: runtimeState.title ?? launchConfiguration.title,
                    workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, backend: launchConfiguration.backend,
                    lifetimePolicy: launchConfiguration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
                    childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
            }
        }

        static func resolveExecutableURL(environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default)
            throws -> URL
        {
            let currentExecutablePath = environment["_"] ?? Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ""
            let currentExecutableDirectory = URL(fileURLWithPath: currentExecutablePath).deletingLastPathComponent()
            let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            let bundledResourceDirectory = currentExecutableDirectory.deletingLastPathComponent().appendingPathComponent(
                "Resources", isDirectory: true)
            let candidates = [
                environment["SPACES_TERMINAL_SERVICE_EXECUTABLE"],
                currentExecutableDirectory.appendingPathComponent("SpacesTerminalService", isDirectory: false).path(),
                Bundle.main.resourceURL?.appendingPathComponent("SpacesTerminalService", isDirectory: false).path(),
                bundledResourceDirectory.appendingPathComponent("SpacesTerminalService", isDirectory: false).path(),
                currentDirectory.appendingPathComponent("apps/macos/.build/debug/SpacesTerminalService", isDirectory: false).path(),
                currentDirectory.appendingPathComponent("apps/macos/.build/release/SpacesTerminalService", isDirectory: false).path(),
                currentDirectory.appendingPathComponent(".build/debug/SpacesTerminalService", isDirectory: false).path(),
                currentDirectory.appendingPathComponent(".build/release/SpacesTerminalService", isDirectory: false).path(),
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

            for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate, isDirectory: false)
            }

            throw TerminalServiceError.executableNotFound
        }

        private static func isRunningUnderXCTest() -> Bool {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
            if NSClassFromString("XCTestCase") != nil { return true }
            if CommandLine.arguments.contains(where: { $0.hasSuffix(".xctest") }) { return true }
            return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        }

        private static func isProcessAlive(pid: Int) -> Bool {
            guard pid > 0 else { return false }
            if kill(pid_t(pid), 0) == 0 { return true }
            return errno == EPERM
        }
    }

    public enum TerminalServiceError: LocalizedError {
        case executableNotFound
        case requestFailed(String)
        case serviceStartupTimedOut(String)

        public var errorDescription: String? {
            switch self {
            case .executableNotFound: "The SpacesTerminalService executable is required to run built-in terminal sessions."
            case .requestFailed(let message): message
            case .serviceStartupTimedOut(let path): "Timed out waiting for SpacesTerminalService to start from \(path)."
            }
        }
    }
#endif
