import Darwin
import Dispatch
import Foundation
import spacesmobilecore
import spacesterminalcore
import workspacecore

public final class SpacesMobileBridgeServer: @unchecked Sendable {
    private struct StreamRelay {
        let relaySocketFD: Int32
        let relayQueue: DispatchQueue
        let relaySource: DispatchSourceRead
        let heartbeatTimer: DispatchSourceTimer?
    }

    private final class RequestConnection: @unchecked Sendable {
        private let clientFD: Int32
        private let server: SpacesMobileBridgeServer
        private var buffer = Data()
        private var shouldCloseClient = true

        init(clientFD: Int32, server: SpacesMobileBridgeServer) {
            self.clientFD = clientFD
            self.server = server
        }

        func run() {
            defer {
                server.trace("request_connection_close client_fd=\(clientFD) should_close=\(shouldCloseClient)")
                if shouldCloseClient {
                    shutdown(clientFD, SHUT_RDWR)
                    close(clientFD)
                }
            }

            do {
                while let requestData = try readNextRequest() {
                    let request = try SpacesMobileBridgeCodec.decodeRequest(requestData)
                    server.trace(
                        "request_received client_fd=\(clientFD) command=\(request.command) session=\(request.sessionID ?? "-") client=\(request.clientID ?? request.client?.id ?? "-")"
                    )
                    try server.authorize(request)
                    guard request.command != "subscribe" else {
                        server.trace("request_subscribe client_fd=\(clientFD) session=\(request.sessionID ?? "-")")
                        try server.queue.sync { try server.handleSubscribeRequest(request, clientFD: clientFD) }
                        shouldCloseClient = false
                        return
                    }
                    let response = try server.handleRequest(request)
                    server.trace(
                        "request_response client_fd=\(clientFD) command=\(request.command) ok=\(response.ok) message=\(response.message.replacingOccurrences(of: "\n", with: "\\n"))"
                    )
                    try server.writeResponse(response, to: clientFD)
                }
            } catch {
                server.trace("request_error client_fd=\(clientFD) error=\(String(describing: error).replacingOccurrences(of: "\n", with: "\\n"))")
                let response = SpacesMobileBridgeResponse(ok: false, message: String(describing: error))
                try? server.writeResponse(response, to: clientFD)
            }
        }

        private func readNextRequest() throws -> Data? {
            while true {
                if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.prefix(upTo: newlineIndex)
                    buffer.removeSubrange(...newlineIndex)
                    if line.isEmpty { continue }
                    return Data(line)
                }

                var readBuffer = [UInt8](repeating: 0, count: 4096)
                let count = read(clientFD, &readBuffer, readBuffer.count)
                if count == 0 {
                    if buffer.isEmpty { return nil }
                    defer { buffer.removeAll(keepingCapacity: false) }
                    return Data(buffer)
                }
                if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                buffer.append(readBuffer, count: count)
            }
        }
    }

    private let host: String
    private let port: Int
    private let pairingCode: String
    private let pairingStore: SpacesMobilePairingStore
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private let traceEnabled = ProcessInfo.processInfo.environment["SPACES_MOBILE_BRIDGE_TRACE"] == "1"

    private var listenSocketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var streamRelays: [Int32: StreamRelay] = [:]
    private var running = false

    public init(host: String, port: Int, pairingCode: String, pairingStore: SpacesMobilePairingStore? = nil) throws {
        self.host = host
        self.port = port
        self.pairingCode = pairingCode
        if let pairingStore { self.pairingStore = pairingStore } else { self.pairingStore = try SpacesMobilePairingStore() }
        queue = DispatchQueue(label: "spaces.mobile.bridge")
    }

    public private(set) var listeningPort: Int = 0

    public var isRunning: Bool {
        stateLock.lock()
        let value = running
        stateLock.unlock()
        return value
    }

    public static func generatePairingCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    public func start() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        try setNoSIGPIPE(socketFD)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            close(socketFD)
            throw POSIXError(.EADDRNOTAVAIL)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }

        guard listen(socketFD, 64) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }
        try setNonBlocking(socketFD)

        listeningPort = try Self.resolveListeningPort(socketFD: socketFD)
        listenSocketFD = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptReadyConnections() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listenSocketFD >= 0 { close(self.listenSocketFD) }
            self.listenSocketFD = -1
            self.setRunning(false)
        }
        acceptSource = source
        source.resume()
        setRunning(true)
    }

    public func stop() {
        queue.async {
            for clientFD in Array(self.streamRelays.keys) { self.closeStreamRelay(clientFD: clientFD) }
            self.acceptSource?.cancel()
            self.acceptSource = nil
        }
    }

    private func acceptReadyConnections() {
        while true {
            let clientFD = accept(listenSocketFD, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { return }
                return
            }
            do {
                trace("request_connection_accept client_fd=\(clientFD)")
                try setNoSIGPIPE(clientFD)
                try setBlocking(clientFD)
                let requestQueue = DispatchQueue(label: "spaces.mobile.bridge.request.\(clientFD)")
                requestQueue.async { [weak self] in
                    guard let self else {
                        shutdown(clientFD, SHUT_RDWR)
                        close(clientFD)
                        return
                    }
                    RequestConnection(clientFD: clientFD, server: self).run()
                }
            } catch {
                trace(
                    "request_connection_accept_error client_fd=\(clientFD) error=\(String(describing: error).replacingOccurrences(of: "\n", with: "\\n"))"
                )
                let response = SpacesMobileBridgeResponse(ok: false, message: String(describing: error))
                try? writeResponse(response, to: clientFD)
                shutdown(clientFD, SHUT_RDWR)
                close(clientFD)
            }
        }
    }

    private func handleRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        switch request.command {
        case "pair":
            guard let clientApp = request.clientApp else {
                return SpacesMobileBridgeResponse(ok: false, message: SpacesMobilePairingError.missingClientApp.localizedDescription)
            }
            let issuedToken = try pairingStore.issueToken(for: clientApp, pairingCode: request.pairingCode ?? "", expectedPairingCode: pairingCode)
            return SpacesMobileBridgeResponse(ok: true, message: "Paired iOS client.", issuedAuthToken: issuedToken)
        case "ping": return SpacesMobileBridgeResponse(ok: true, message: "pong")
        case "overview": return SpacesMobileBridgeResponse(ok: true, message: "Loaded mobile overview.", overview: try loadOverview())
        case "state": return try handleStateRequest(request)
        case "attach": return try handleTerminalControlRequest(request, command: "attach")
        case "detach": return try handleTerminalControlRequest(request, command: "detach")
        case "heartbeat": return try handleTerminalControlRequest(request, command: "heartbeat")
        case "takeover": return try handleTerminalControlRequest(request, command: "takeover")
        case "send": return try handleTerminalControlRequest(request, command: "send")
        case "key": return try handleTerminalControlRequest(request, command: "key")
        case "resize": return try handleTerminalControlRequest(request, command: "resize")
        default: return SpacesMobileBridgeResponse(ok: false, message: "Unsupported mobile bridge command '\(request.command)'.")
        }
    }

    private func authorize(_ request: SpacesMobileBridgeRequest) throws {
        guard request.command != "pair" else { return }
        do { try pairingStore.authorize(clientApp: request.clientApp, authToken: request.authToken) } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw NSError(domain: "SpacesMobileBridgeServer", code: 401, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func handleTerminalControlRequest(_ request: SpacesMobileBridgeRequest, command: String) throws -> SpacesMobileBridgeResponse {
        guard let sessionID = request.sessionID else { return SpacesMobileBridgeResponse(ok: false, message: "Missing session ID.") }
        let startedAt = Date()
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            return SpacesMobileBridgeResponse(ok: false, message: "Terminal session '\(sessionID)' is not available.")
        }

        let terminalRequest = TerminalControlRequest(
            command: command, text: request.text, key: request.key, clientID: request.clientID, client: request.client,
            attachmentMode: request.attachmentMode, columns: request.columns, rows: request.rows, appendNewline: request.appendNewline)
        let response = try TerminalControlClient.send(request: terminalRequest, socketPath: paths.controlSocketPath)
        TerminalPerformance.logMetric(
            "mobile_bridge_\(command)", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: response.ok)
        return SpacesMobileBridgeResponse(ok: response.ok, message: response.message)
    }

    private func loadOverview() throws -> SpacesMobileOverviewPayload {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let projects = try store.projects()
        let workspaces = try projects.flatMap { project in
            try store.workspaces(projectID: project.id).map { workspace in
                SpacesMobileOverviewBuilder.WorkspaceDescriptor(project: project, workspace: workspace)
            }
        }
        let sessions = try TerminalSessionCatalog.listLiveSessions()
        return SpacesMobileOverviewBuilder.build(workspaces: workspaces, sessions: sessions)
    }

    private func handleStateRequest(_ request: SpacesMobileBridgeRequest) throws -> SpacesMobileBridgeResponse {
        guard let sessionID = request.sessionID else { return SpacesMobileBridgeResponse(ok: false, message: "Missing session ID.") }
        let startedAt = Date()
        let payload = try loadCurrentState(sessionID: sessionID, includeOutputHistory: request.includeOutputHistory)
        TerminalPerformance.logMetric(
            "mobile_bridge_state", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
        return SpacesMobileBridgeResponse(ok: true, message: "Loaded terminal state.", sessionState: payload)
    }

    private func handleSubscribeRequest(_ request: SpacesMobileBridgeRequest, clientFD: Int32) throws {
        guard let sessionID = request.sessionID else {
            try writeResponse(SpacesMobileBridgeResponse(ok: false, message: "Missing session ID."), to: clientFD)
            shutdown(clientFD, SHUT_RDWR)
            close(clientFD)
            return
        }
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
            try writeResponse(
                SpacesMobileBridgeResponse(ok: false, message: "Terminal session '\(sessionID)' has no live state stream."), to: clientFD)
            shutdown(clientFD, SHUT_RDWR)
            close(clientFD)
            return
        }

        let startedAt = Date()
        let relaySocketFD = try connectUnixSocket(path: paths.subscriptionSocketPath)
        try setNonBlocking(relaySocketFD)
        try setNonBlocking(clientFD)

        let relayQueue = DispatchQueue(label: "spaces.mobile.bridge.stream.\(sessionID).\(clientFD)")
        let relaySource = DispatchSource.makeReadSource(fileDescriptor: relaySocketFD, queue: relayQueue)
        relaySource.setEventHandler { [weak self] in self?.relayStateData(from: relaySocketFD, to: clientFD) }
        relaySource.setCancelHandler { close(relaySocketFD) }

        let heartbeatTimer: DispatchSourceTimer?
        if let clientID = request.clientID {
            let timer = DispatchSource.makeTimerSource(queue: relayQueue)
            timer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
            timer.setEventHandler {
                _ = try? TerminalControlClient.send(
                    request: TerminalControlRequest(command: "heartbeat", clientID: clientID), socketPath: paths.controlSocketPath)
            }
            heartbeatTimer = timer
        } else {
            heartbeatTimer = nil
        }

        streamRelays[clientFD] = StreamRelay(
            relaySocketFD: relaySocketFD, relayQueue: relayQueue, relaySource: relaySource, heartbeatTimer: heartbeatTimer)

        relaySource.resume()
        heartbeatTimer?.resume()

        TerminalPerformance.logMetric(
            "mobile_bridge_subscribe", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
    }

    private func relayStateData(from relaySocketFD: Int32, to clientFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(relaySocketFD, &buffer, buffer.count)
            if count == 0 {
                queue.async { [weak self] in self?.closeStreamRelay(clientFD: clientFD) }
                return
            }
            if count < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { return }
                queue.async { [weak self] in self?.closeStreamRelay(clientFD: clientFD) }
                return
            }
            let data = Data(buffer.prefix(count))
            if !Self.writeAll(data: data, to: clientFD) {
                queue.async { [weak self] in self?.closeStreamRelay(clientFD: clientFD) }
                return
            }
        }
    }

    private func closeStreamRelay(clientFD: Int32) {
        guard let relay = streamRelays.removeValue(forKey: clientFD) else { return }
        trace("stream_relay_close client_fd=\(clientFD)")
        relay.heartbeatTimer?.cancel()
        relay.relaySource.cancel()
        shutdown(relay.relaySocketFD, SHUT_RDWR)
        shutdown(clientFD, SHUT_RDWR)
        close(clientFD)
    }

    private func connectUnixSocket(path: String) throws -> Int32 {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try setNoSIGPIPE(socketFD)
        var address = try makeUnixSocketAddress(path: path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }
        return socketFD
    }

    private func makeUnixSocketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8Path = path.utf8CString
        guard utf8Path.count <= maxLength else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            _ = utf8Path.withUnsafeBufferPointer { buffer in memcpy(pointer, buffer.baseAddress, buffer.count) }
        }
        return address
    }

    private func loadCurrentState(sessionID: String, includeOutputHistory: Bool) throws -> GhosttyRemoteSessionStatePayload {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if includeOutputHistory { return try loadCurrentStateWithOutputHistory(sessionID: sessionID, paths: paths) }
        guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
            throw NSError(
                domain: "SpacesMobileBridgeServer", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' has no live state stream."])
        }

        let socketFD = try connectUnixSocket(path: paths.subscriptionSocketPath)
        defer {
            shutdown(socketFD, SHUT_RDWR)
            close(socketFD)
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(socketFD, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.append(buffer, count: count)
            if let newlineIndex = data.firstIndex(of: 0x0A) {
                data.removeSubrange(newlineIndex..<data.endIndex)
                break
            }
        }

        guard !data.isEmpty else {
            throw NSError(
                domain: "SpacesMobileBridgeServer", code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' did not return a state payload."])
        }
        return try GhosttyRemoteSessionStateCodec.decodeLine(data)
    }

    private func loadCurrentStateWithOutputHistory(sessionID: String, paths: TerminalSessionPaths) throws -> GhosttyRemoteSessionStatePayload {
        let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        let attachmentSnapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)
        let outputURL = URL(fileURLWithPath: paths.outputPath)
        let outputData = try? Data(contentsOf: outputURL, options: [.mappedIfSafe])

        guard runtimeState != nil || launchConfiguration != nil else {
            throw NSError(
                domain: "SpacesMobileBridgeServer", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' has no persisted state."])
        }

        return GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: "history_seed", emittedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()),
            sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil, runtimeState: runtimeState,
            attachmentSnapshot: attachmentSnapshot, title: runtimeState?.title ?? launchConfiguration?.title ?? sessionID,
            workingDirectory: runtimeState?.workingDirectory ?? launchConfiguration?.workingDirectory ?? "", snapshot: nil, snapshotText: nil,
            transcriptTail: nil, outputByteCount: outputData?.count, outputData: outputData)
    }

    private func writeResponse(_ response: SpacesMobileBridgeResponse, to fileDescriptor: Int32) throws {
        var data = try SpacesMobileBridgeCodec.encodeResponse(response)
        data.append(0x0A)
        try writeAll(data: data, to: fileDescriptor)
    }

    private func setNonBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func setBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags & ~O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func setNoSIGPIPE(_ fileDescriptor: Int32) throws {
        var yes: Int32 = 1
        guard setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func resolveListeningPort(socketFD: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in getsockname(socketFD, sockaddrPointer, &length) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func writeAll(data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let written = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                if written < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                bytesRemaining -= written
                offset += written
            }
        }
    }

    private static func writeAll(data: Data, to fileDescriptor: Int32) -> Bool {
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var bytesRemaining = rawBuffer.count
                var offset = 0
                while bytesRemaining > 0 {
                    let written = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                    if written < 0 {
                        if errno == EWOULDBLOCK || errno == EAGAIN {
                            Thread.sleep(forTimeInterval: 0.005)
                            continue
                        }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    bytesRemaining -= written
                    offset += written
                }
            }
            return true
        } catch { return false }
    }

    private func trace(_ message: String) {
        guard traceEnabled else { return }
        fputs("spaces-mobile-bridge-trace \(message)\n", stdout)
        fflush(stdout)
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        running = value
        stateLock.unlock()
    }

}
