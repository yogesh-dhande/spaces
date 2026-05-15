import Darwin
import Dispatch
import Foundation

public final class ScriptPTYTerminalSessionRuntime: TerminalSessionBackendRuntime {
    static let defaultInitialColumns = 120
    static let defaultInitialRows = 40

    public let backendKind: TerminalSessionBackendKind = .scriptPTY
    public let launchConfiguration: TerminalSessionLaunchConfiguration
    public let paths: TerminalSessionPaths
    private let now: @Sendable () -> String

    private final class ExitFinalizer: @unchecked Sendable {
        private let lock = NSLock()
        private var didFinalize = false

        func beginIfNeeded() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didFinalize else { return false }
            didFinalize = true
            return true
        }
    }

    private final class QueryResponderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var responder = TerminalQueryResponder(
            columns: ScriptPTYTerminalSessionRuntime.defaultInitialColumns, rows: ScriptPTYTerminalSessionRuntime.defaultInitialRows)

        func responses(for output: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            return responder.responses(for: output)
        }

        func updateTerminalSize(columns: Int, rows: Int) {
            lock.lock()
            defer { lock.unlock() }
            responder.updateTerminalSize(columns: columns, rows: rows)
        }
    }

    public init(
        launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.launchConfiguration = launchConfiguration
        self.paths = paths
        self.now = now
    }

    public func run() throws -> Never {
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        FileManager.default.createFile(atPath: paths.outputPath, contents: nil)
        FileManager.default.createFile(atPath: paths.serviceLogPath, contents: nil)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = try startPTYWrappedProcess(inputPipe: inputPipe, outputPipe: outputPipe)
        let childPID = process.processIdentifier
        try TerminalSessionPersistence.writeRuntimeState(
            TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: childPID,
                state: .running, updatedAt: now()), paths: paths)

        let queue = DispatchQueue(label: "spaces.terminal.session.\(launchConfiguration.sessionID)")
        let scriptInputHandle = inputPipe.fileHandleForWriting
        let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.outputPath))
        try outputHandle.seekToEnd()
        let sessionID = launchConfiguration.sessionID
        let sessionPaths = paths
        let now = self.now
        let queryResponder = QueryResponderBox()
        let isActiveOwner: @Sendable (String) -> Bool = { [sessionPaths] clientID in
            ((try? TerminalSessionPersistence.activeAttachments(paths: sessionPaths)) ?? []).contains { $0.clientID == clientID && $0.mode == .owner }
        }
        let resizePTY: @Sendable (Int, Int) -> Bool = { columns, rows in
            guard columns > 0, rows > 0 else { return false }
            guard let ttyName = Self.controllingTTYName(for: childPID) else { return false }
            return Self.resizeTerminal(named: ttyName, columns: columns, rows: rows)
        }
        let outputFD = outputPipe.fileHandleForReading.fileDescriptor
        let outputFlags = fcntl(outputFD, F_GETFL)
        if outputFlags >= 0 { _ = fcntl(outputFD, F_SETFL, outputFlags | O_NONBLOCK) }
        let drainOutput: @Sendable () -> Void = {
            let chunks = Self.readAvailableOutputChunks(from: outputFD)
            guard !chunks.isEmpty else { return }
            for chunk in chunks {
                try? outputHandle.write(contentsOf: chunk)
                for response in queryResponder.responses(for: chunk) { try? scriptInputHandle.write(contentsOf: response) }
            }
            try? outputHandle.synchronize()
        }
        let outputSource = DispatchSource.makeReadSource(fileDescriptor: outputFD, queue: queue)
        outputSource.setEventHandler {
            guard outputSource.data > 0 else { return }
            drainOutput()
        }
        outputSource.setCancelHandler {
            try? outputPipe.fileHandleForReading.close()
            try? outputHandle.close()
        }

        let controlServer = TerminalControlServer(socketPath: paths.controlSocketPath, queue: queue) { request in
            if let compatibilityFailure = TerminalSessionHostProtocolSupport.validateCompatibility(for: request) { return compatibilityFailure }
            switch request.command {
            case "hello": return TerminalSessionHostProtocolSupport.hello(sessionID: sessionID, backend: self.backendKind)
            case "ping": return TerminalSessionHostProtocolSupport.ping()
            case "attach":
                do {
                    return try TerminalSessionHostProtocolSupport.attach(request: request, sessionID: sessionID, paths: sessionPaths, attachedAt: now)
                } catch { return TerminalControlResponse(ok: false, message: String(describing: error)) }
            case "detach":
                do { return try TerminalSessionHostProtocolSupport.detach(request: request, paths: sessionPaths) } catch {
                    return TerminalControlResponse(ok: false, message: String(describing: error))
                }
            case "snapshot": return TerminalSessionHostProtocolSupport.snapshot(request: request, paths: sessionPaths)
            case "output_size": return TerminalSessionHostProtocolSupport.outputSize(paths: sessionPaths)
            case "read_output_chunk":
                return TerminalSessionHostProtocolSupport.readOutputChunk(request: request, sessionID: sessionID, paths: sessionPaths)
            case "send":
                let startedAt = Date()
                if let clientID = request.clientID, !isActiveOwner(clientID) {
                    TerminalPerformance.logMetric(
                        "terminal_control_send", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: false)
                    return TerminalSessionHostProtocolSupport.ownerRequired("Only the active owner can send input.")
                }
                guard let text = request.text else { return TerminalSessionHostProtocolSupport.missingParameter("Missing text payload.") }
                guard let data = (text + (request.appendNewline ? "\n" : "")).data(using: .utf8) else {
                    return TerminalControlResponse(ok: false, message: "Unable to encode terminal input.", errorCode: .internalError)
                }
                try scriptInputHandle.write(contentsOf: data)
                TerminalPerformance.logMetric(
                    "terminal_control_send", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                    success: true, detail: "bytes=\(data.count)")
                return TerminalControlResponse(ok: true, message: "Sent input.")
            case "key":
                let startedAt = Date()
                if let clientID = request.clientID, !isActiveOwner(clientID) {
                    TerminalPerformance.logMetric(
                        "terminal_control_key", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: false)
                    return TerminalSessionHostProtocolSupport.ownerRequired("Only the active owner can send keys.")
                }
                guard let key = request.key, let bytes = TerminalKeyInput.bytes(for: key) else {
                    return TerminalControlResponse(ok: false, message: "Unsupported terminal key.", errorCode: .missingParameter)
                }
                try scriptInputHandle.write(contentsOf: bytes)
                TerminalPerformance.logMetric(
                    "terminal_control_key", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                    detail: "key=\(key)")
                return TerminalControlResponse(ok: true, message: "Sent key.")
            case "mouse":
                let startedAt = Date()
                if let clientID = request.clientID, !isActiveOwner(clientID) {
                    TerminalPerformance.logMetric(
                        "terminal_control_mouse", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: false)
                    return TerminalSessionHostProtocolSupport.ownerRequired("Only the active owner can send mouse input.")
                }
                guard let sequence = request.mouseSequence, let data = sequence.data(using: .utf8) else {
                    return TerminalControlResponse(ok: false, message: "Missing terminal mouse payload.", errorCode: .missingParameter)
                }
                try scriptInputHandle.write(contentsOf: data)
                TerminalPerformance.logMetric(
                    "terminal_control_mouse", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                    success: true, detail: "bytes=\(data.count)")
                return TerminalControlResponse(ok: true, message: "Sent mouse input.")
            case "resize":
                let startedAt = Date()
                if let clientID = request.clientID, !isActiveOwner(clientID) {
                    TerminalPerformance.logMetric(
                        "terminal_control_resize", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: false)
                    return TerminalSessionHostProtocolSupport.ownerRequired("Only the active owner can resize the session.")
                }
                guard let columns = request.columns, let rows = request.rows, columns > 0, rows > 0 else {
                    return TerminalSessionHostProtocolSupport.missingParameter("Missing terminal size.")
                }
                guard resizePTY(columns, rows) else {
                    TerminalPerformance.logMetric(
                        "terminal_control_resize", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: false, detail: "cols=\(columns) rows=\(rows)")
                    return TerminalSessionHostProtocolSupport.runtimeUnavailable("Unable to resize terminal session.")
                }
                queryResponder.updateTerminalSize(columns: columns, rows: rows)
                TerminalPerformance.logMetric(
                    "terminal_control_resize", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                    success: true, detail: "cols=\(columns) rows=\(rows)")
                return TerminalControlResponse(ok: true, message: "Resized terminal session.")
            case "takeover":
                let startedAt = Date()
                guard let clientID = request.clientID, !clientID.isEmpty else {
                    TerminalPerformance.logMetric(
                        "terminal_control_takeover", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: false)
                    return TerminalSessionHostProtocolSupport.missingParameter("Missing client ID.")
                }
                do {
                    try TerminalSessionPersistence.transferOwnership(
                        sessionID: sessionID, newOwnerClientID: clientID, paths: sessionPaths, transferredAt: now())
                    TerminalPerformance.logMetric(
                        "terminal_control_takeover", target: "session=\(sessionID) client=\(clientID)",
                        elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
                    return TerminalControlResponse(ok: true, message: "Transferred terminal ownership.")
                } catch {
                    TerminalPerformance.logMetric(
                        "terminal_control_takeover", target: "session=\(sessionID) client=\(clientID)",
                        elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false)
                    return TerminalControlResponse(ok: false, message: String(describing: error))
                }
            case "terminate":
                let startedAt = Date()
                if let clientID = request.clientID, !isActiveOwner(clientID) {
                    TerminalPerformance.logMetric(
                        "terminal_control_terminate", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        success: false)
                    return TerminalSessionHostProtocolSupport.ownerRequired("Only the active owner can terminate the session.")
                }
                process.terminate()
                TerminalPerformance.logMetric(
                    "terminal_control_terminate", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                    success: true)
                return TerminalControlResponse(ok: true, message: "Terminating terminal session.")
            default: return TerminalSessionHostProtocolSupport.unsupportedCommand(request.command)
            }
        }
        try controlServer.start()

        let exitFinalizer = ExitFinalizer()
        let finalizeExit: @Sendable (Process) -> Void = { [paths, now, launchConfiguration] terminatedProcess in
            queue.async {
                guard exitFinalizer.beginIfNeeded() else { return }
                drainOutput()
                let state: TerminalSessionState = terminatedProcess.terminationReason == .exit ? .exited : .failed
                try? TerminalSessionPersistence.writeRuntimeState(
                    TerminalSessionRuntimeState(
                        sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: getpid(), childPID: childPID,
                        state: state, updatedAt: now(), exitedAt: now()), paths: paths)
                outputSource.cancel()
                controlServer.stop()
                try? scriptInputHandle.close()
                exit(terminatedProcess.terminationReason == .exit ? Int32(terminatedProcess.terminationStatus) : 1)
            }
        }
        process.terminationHandler = { terminatedProcess in finalizeExit(terminatedProcess) }

        outputSource.resume()
        dispatchMain()
    }

    private func startPTYWrappedProcess(inputPipe: Pipe, outputPipe: Pipe) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q", "/dev/null", launchConfiguration.shell, "-lc",
            Self.makeLaunchCommand(shell: launchConfiguration.shell, command: launchConfiguration.command),
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: launchConfiguration.workingDirectory, isDirectory: true)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        return process
    }

    static func makeLaunchCommand(shell: String, command: String?) -> String {
        let initialSizePrefix = "stty rows \(defaultInitialRows) cols \(defaultInitialColumns) 2>/dev/null;"
        if let command, !command.isEmpty { return "\(initialSizePrefix) \(command)" }
        return "\(initialSizePrefix) exec \(singleQuotedShellEscape(shell)) -l"
    }

    private static func singleQuotedShellEscape(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'" }

    private static func controllingTTYName(for pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let tty = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tty.isEmpty, tty != "??" else { return nil }
            return tty
        } catch { return nil }
    }

    private static func resizeTerminal(named ttyName: String, columns: Int, rows: Int) -> Bool {
        let ttyPath = ttyName.hasPrefix("/") ? ttyName : "/dev/\(ttyName)"
        let fileDescriptor = open(ttyPath, O_RDWR | O_NOCTTY)
        guard fileDescriptor >= 0 else { return false }
        defer { close(fileDescriptor) }
        var windowSize = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        return ioctl(fileDescriptor, TIOCSWINSZ, &windowSize) == 0
    }

    private static func readAvailableOutputChunks(from fileDescriptor: Int32, chunkSize: Int = 8192) -> [Data] {
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var chunks = [Data]()
        while true {
            let count = read(fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                chunks.append(Data(buffer.prefix(Int(count))))
                continue
            }
            if count == 0 { return chunks }
            if errno == EAGAIN || errno == EWOULDBLOCK { return chunks }
            return chunks
        }
    }
}
