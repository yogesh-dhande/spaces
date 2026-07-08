import Dispatch
import Foundation
import spacesdevicecore
import spacesterminalcore
import workspacecore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
#if canImport(Network)
    import Network
#endif
#if canImport(OpenSSL)
    import OpenSSL
#endif
#if canImport(Security)
    @preconcurrency import Security
#endif

protocol SpacesDevicePairingStoreProtocol: Sendable {
    func issueToken(for clientApp: SpacesDeviceClientApp, presentedToken: String?) throws -> String
    func listDevices() throws -> [SpacesDevicePairedClient]
    func revoke(installationID: String) throws
    func removeAll() throws
    func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws
    func validate(clientApp: SpacesDeviceClientApp) throws
}

extension SpacesDevicePairingStore: SpacesDevicePairingStoreProtocol {}

/// Performance-logging attributes describing a terminal state-stream relay payload.
/// Shared by the Linux and Network device-API server relay paths.
private func deviceAPIStreamRelayAttributes(for data: Data) -> [String: String] {
    var attributes: [String: String] = [
        "payload_bytes": String(data.count), "payload_count": String(data.split(separator: 0x0A, omittingEmptySubsequences: true).count),
    ]
    guard let firstLine = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first,
        let payload = try? GhosttyRemoteSessionStateCodec.decodeLine(Data(firstLine))
    else {
        attributes["render_update"] = "unknown"
        return attributes
    }
    attributes["reason"] = payload.reason
    attributes["render_update"] = payload.renderUpdate == nil ? "0" : "1"
    attributes["render_update_bytes"] = String(payload.renderUpdate?.count ?? 0)
    if let update = payload.decodedRenderUpdate {
        attributes["frame_kind"] = update.frameKindMetricValue
        attributes["operation_count"] = String(update.operationCount)
        attributes["changed_cell_count"] = String(update.changedCellCount)
        attributes["scroll_operation_count"] = String(update.scrollOperationCount)
        attributes["base_revision"] = update.baseRevision.map(String.init) ?? "nil"
        attributes["full_frame_fallback_reason"] = update.fallbackReason ?? "none"
    }
    attributes["target_revision"] = payload.screenStateRevision.map(String.init) ?? "nil"
    return attributes
}

public final class SpacesDeviceAPIServer: @unchecked Sendable {
    private static let streamRelayReadBufferSize = 256 * 1024
    private static let defaultTerminalLinkTransferAuthorizationTTL: TimeInterval = 10 * 60
    static let terminalPasteImageMaxBytes = 10 * 1024 * 1024
    private static let terminalPasteImageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp",
    ]

    #if canImport(Network) && canImport(Security)
        private struct NetworkShaper: Sendable {
            static let profileEnvironmentKey = "SPACES_DEVICE_API_NETWORK_PROFILE"
            static let rttEnvironmentKey = "SPACES_DEVICE_API_NETWORK_RTT_MS"
            static let bandwidthEnvironmentKey = "SPACES_DEVICE_API_NETWORK_BANDWIDTH_BPS"
            static let chunkEnvironmentKey = "SPACES_DEVICE_API_NETWORK_CHUNK_BYTES"

            let profile: String
            let rttMS: Int
            let bandwidthBPS: Int
            let chunkBytes: Int

            var isEnabled: Bool { profile != "local" && (rttMS > 0 || bandwidthBPS > 0 || chunkBytes > 0) }

            private final class SendChain: @unchecked Sendable {
                private let chunks: [Data]
                private let connection: NWConnection
                private let queue: DispatchQueue
                private let isComplete: Bool
                private let interChunkDelayMicroseconds: @Sendable (Int) -> Int
                private let onSendBegin: @Sendable () -> Void
                private let completion: @Sendable (Error?) -> Void

                init(
                    chunks: [Data], connection: NWConnection, queue: DispatchQueue, isComplete: Bool,
                    interChunkDelayMicroseconds: @escaping @Sendable (Int) -> Int, onSendBegin: @escaping @Sendable () -> Void,
                    completion: @escaping @Sendable (Error?) -> Void
                ) {
                    self.chunks = chunks
                    self.connection = connection
                    self.queue = queue
                    self.isComplete = isComplete
                    self.interChunkDelayMicroseconds = interChunkDelayMicroseconds
                    self.onSendBegin = onSendBegin
                    self.completion = completion
                }

                func send(index: Int) {
                    guard index < chunks.count else {
                        completion(nil)
                        return
                    }
                    let chunk = chunks[index]
                    if index == 0 { onSendBegin() }
                    connection.send(
                        content: chunk, contentContext: .defaultMessage, isComplete: isComplete && index == chunks.count - 1,
                        completion: .contentProcessed { [self] error in
                            if let error {
                                self.completion(error)
                                return
                            }
                            let delayMicroseconds = self.interChunkDelayMicroseconds(chunk.count)
                            if delayMicroseconds <= 0 {
                                self.queue.async { self.send(index: index + 1) }
                            } else {
                                self.queue.asyncAfter(deadline: .now() + .microseconds(delayMicroseconds)) { self.send(index: index + 1) }
                            }
                        })
                }
            }

            init(environment: [String: String] = ProcessInfo.processInfo.environment) {
                let resolvedProfile = environment[Self.profileEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "local"
                profile = resolvedProfile.isEmpty ? "local" : resolvedProfile
                let constrained = profile == "ios-constrained"
                rttMS = Self.intValue(environment[Self.rttEnvironmentKey], fallback: constrained ? 80 : 0)
                bandwidthBPS = Self.intValue(environment[Self.bandwidthEnvironmentKey], fallback: constrained ? 8_000_000 : 0)
                chunkBytes = Self.intValue(environment[Self.chunkEnvironmentKey], fallback: constrained ? 16 * 1024 : 0)
            }

            func send(
                content data: Data, to connection: NWConnection, on queue: DispatchQueue, onSendBegin: @escaping @Sendable () -> Void = {},
                isComplete: Bool = false, applyInitialDelay: Bool = true, applyBandwidthDelay: Bool = true,
                completion: @escaping @Sendable (Error?) -> Void
            ) {
                guard isEnabled, !data.isEmpty else {
                    onSendBegin()
                    connection.send(content: data, contentContext: .defaultMessage, isComplete: isComplete, completion: .contentProcessed(completion))
                    return
                }

                let chunks = chunked(data)
                let initialDelay = DispatchTimeInterval.milliseconds(applyInitialDelay ? max(rttMS / 2, 0) : 0)
                let bandwidthBPS = applyBandwidthDelay ? bandwidthBPS : 0
                let chain = SendChain(
                    chunks: chunks, connection: connection, queue: queue, isComplete: isComplete,
                    interChunkDelayMicroseconds: { byteCount in Self.interChunkDelayMicroseconds(forByteCount: byteCount, bandwidthBPS: bandwidthBPS)
                    }, onSendBegin: onSendBegin, completion: completion)
                queue.asyncAfter(deadline: .now() + initialDelay) { chain.send(index: 0) }
            }

            private func chunked(_ data: Data) -> [Data] {
                let size = chunkBytes > 0 ? chunkBytes : data.count
                guard data.count > size else { return [data] }
                var chunks: [Data] = []
                chunks.reserveCapacity(Int(ceil(Double(data.count) / Double(size))))
                var offset = data.startIndex
                while offset < data.endIndex {
                    let end = data.index(offset, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
                    chunks.append(data[offset..<end])
                    offset = end
                }
                return chunks
            }

            private static func interChunkDelayMicroseconds(forByteCount byteCount: Int, bandwidthBPS: Int) -> Int {
                guard bandwidthBPS > 0, byteCount > 0 else { return 0 }
                let bytesPerSecond = Double(bandwidthBPS) / 8.0
                let seconds = Double(byteCount) / max(bytesPerSecond, 1)
                return max(Int((seconds * 1_000_000).rounded()), 0)
            }

            private static func intValue(_ rawValue: String?, fallback: Int) -> Int {
                guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else { return fallback }
                return max(Int(rawValue) ?? fallback, 0)
            }
        }

        private struct StreamRelay {
            let sessionID: String
            let installationID: String
            let relaySocketFD: Int32
            let relayQueue: DispatchQueue
            let relaySource: DispatchSourceRead
            let heartbeatTimer: DispatchSourceTimer?
            let connection: NWConnection
            let sendSequencer: StreamSendSequencer
        }

        private final class StreamSendSequencer: @unchecked Sendable {
            typealias Operation = @Sendable (@escaping @Sendable (Error?) -> Void) -> Void

            private let queueKey: DispatchSpecificKey<Void>
            private var pendingOperations: [Operation] = []
            private var isRunning = false

            init(queueKey: DispatchSpecificKey<Void>) { self.queueKey = queueKey }

            func enqueue(_ operation: @escaping Operation) {
                assertOnOwningQueue()
                pendingOperations.append(operation)
                startNextIfNeeded()
            }

            private func startNextIfNeeded() {
                assertOnOwningQueue()
                guard !isRunning, !pendingOperations.isEmpty else { return }
                isRunning = true
                let operation = pendingOperations.removeFirst()
                operation { [weak self] _ in self?.finishCurrent() }
            }

            private func finishCurrent() {
                assertOnOwningQueue()
                isRunning = false
                startNextIfNeeded()
            }

            private func assertOnOwningQueue() {
                precondition(DispatchQueue.getSpecific(key: queueKey) != nil, "StreamSendSequencer must be used on its owning queue.")
            }
        }

        private final class RequestConnection: @unchecked Sendable {
            fileprivate let connection: NWConnection
            private let server: SpacesDeviceAPIServer
            private let peerID: String
            private var buffer = Data()
            private var didSubscribe = false
            private var didReceiveEOF = false

            init(connection: NWConnection, server: SpacesDeviceAPIServer) {
                self.connection = connection
                self.server = server
                peerID = String(describing: connection.endpoint)
            }

            func start(on queue: DispatchQueue) {
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.server.trace("request_connection_ready peer=\(self.peerID)")
                        self.receiveNext()
                    case .failed(let error):
                        self.server.trace("request_connection_failed peer=\(self.peerID) error=\(error)")
                        self.server.closeRequestConnectionAfterNetworkUpdate(connection: self.connection, cancelNetworkConnection: true)
                    case .cancelled:
                        self.server.trace("request_connection_cancelled peer=\(self.peerID)")
                        self.server.closeRequestConnectionAfterNetworkUpdate(connection: self.connection, cancelNetworkConnection: false)
                    default: break
                    }
                }
                connection.start(queue: queue)
            }

            private func receiveNext() {
                guard !didSubscribe else { return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
                    guard let self else { return }
                    if let content, !content.isEmpty { self.buffer.append(content) }
                    if let error {
                        self.server.trace("request_receive_error peer=\(self.peerID) error=\(error)")
                        self.connection.cancel()
                        return
                    }
                    if isComplete { self.didReceiveEOF = true }
                    if !self.buffer.isEmpty || self.didReceiveEOF {
                        self.processBufferedLines()
                        return
                    }
                    self.receiveNext()
                }
            }

            private func processBufferedLines() {
                guard !didSubscribe else { return }
                guard server.acceptingRequests else {
                    connection.cancel()
                    return
                }
                guard let newlineIndex = buffer.firstIndex(of: 0x0A) else {
                    if didReceiveEOF {
                        if !buffer.isEmpty { server.trace("request_incomplete peer=\(peerID) bytes=\(buffer.count)") }
                        connection.cancel()
                    } else {
                        receiveNext()
                    }
                    return
                }

                let line = Data(buffer.prefix(upTo: newlineIndex))
                buffer.removeSubrange(...newlineIndex)
                guard !line.isEmpty else {
                    processBufferedLines()
                    return
                }

                do {
                    let request = try SpacesDeviceAPICodec.decodeRequest(line)
                    server.trace(
                        "request_received peer=\(peerID) command=\(request.commandName) session=\(request.sessionID ?? "-") client=\(request.clientID ?? request.clientApp?.installationID ?? "-")"
                    )
                    try server.authorize(request)
                    guard !request.command.isSubscriptionCommand else {
                        didSubscribe = true
                        try server.handleSubscribeRequest(request, connection: connection)
                        return
                    }
                    let response = try server.handleRequest(request, peerID: peerID)
                    server.sendResponse(response, to: connection) { [weak self] error in
                        guard let self else { return }
                        if let error {
                            self.server.trace("request_response_error peer=\(self.peerID) error=\(error)")
                            self.connection.cancel()
                            return
                        }
                        self.processBufferedLines()
                    }
                } catch {
                    server.trace("request_error peer=\(peerID) error=\(String(describing: error).replacingOccurrences(of: "\n", with: "\\n"))")
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    let response = SpacesDeviceAPIResponse(ok: false, message: message, errorCode: SpacesDeviceAPIServer.errorCode(for: error))
                    server.sendResponse(response, to: connection) { [weak self] _ in
                        self?.connection.cancel()
                    }
                }
            }
        }
    #endif

    private struct TerminalLinkTransferAuthorization: Sendable {
        let sessionID: String
        let resolvedPath: String
        let expiresAt: Date
    }

    #if os(Linux) && canImport(OpenSSL)
        private struct LinuxSubscription: Sendable {
            let sessionID: String
            let installationID: String
            let subscriptionSocketPath: String
            let controlSocketPath: String
            let clientID: String?
        }

        private enum LinuxSubscribeAction: Sendable {
            case response(SpacesDeviceAPIResponse)
            case finalPayload(GhosttyRemoteSessionStatePayload)
            case relay(LinuxSubscription)
        }

        private final class LinuxServer: @unchecked Sendable {
            private let host: String
            private let port: Int
            private let identity: TerminalServiceTLSIdentity
            private let server: SpacesDeviceAPIServer
            private let queue: DispatchQueue
            private var listenSocketFD: Int32 = -1
            private var acceptSource: DispatchSourceRead?
            private var sslContext: OpaquePointer?
            private let activeConnectionLock = NSLock()
            private var activeConnectionsByFD: [Int32: String] = [:]

            private(set) var listeningPort: Int = 0

            init(host: String, port: Int, identity: TerminalServiceTLSIdentity, server: SpacesDeviceAPIServer, queue: DispatchQueue) {
                self.host = host
                self.port = port
                self.identity = identity
                self.server = server
                self.queue = queue
            }

            func start(timeout: TimeInterval = 5) throws {
                guard (0...Int(UInt16.max)).contains(port) else { throw POSIXError(.EINVAL) }
                let context = try Self.makeSSLContext(identity: identity)
                let socketFD = try Self.makeListenSocket(host: host, port: port)
                try Self.setCloseOnExec(socketFD)
                try Self.setNonBlocking(socketFD)
                sslContext = context
                listenSocketFD = socketFD
                listeningPort = try Self.resolveListeningPort(socketFD: socketFD)

                let startup = DispatchSemaphore(value: 0)
                let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptReadyConnections() }
                source.setCancelHandler { [weak self] in
                    guard let self else { return }
                    if self.listenSocketFD >= 0 { close(self.listenSocketFD) }
                    if let sslContext = self.sslContext { SSL_CTX_free(sslContext) }
                    self.listenSocketFD = -1
                    self.sslContext = nil
                }
                acceptSource = source
                source.resume()
                startup.signal()
                guard startup.wait(timeout: .now() + timeout) == .success else { throw POSIXError(.ETIMEDOUT) }
            }

            func stop() {
                acceptSource?.cancel()
                acceptSource = nil
                closeActiveConnections(where: { _ in true })
            }

            func closeConnections(forInstallationID installationID: String) { closeActiveConnections { $0 == installationID } }

            private func acceptReadyConnections() {
                while true {
                    let clientFD = accept(listenSocketFD, nil, nil)
                    if clientFD < 0 {
                        if errno == EWOULDBLOCK || errno == EAGAIN { return }
                        return
                    }
                    do {
                        try Self.setCloseOnExec(clientFD)
                        try Self.setBlocking(clientFD)
                        Self.setSocketTimeout(clientFD, seconds: 120)
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            guard let self else {
                                close(clientFD)
                                return
                            }
                            do { try self.handleClient(fileDescriptor: clientFD) } catch { self.server.trace("linux_request_error \(error)") }
                        }
                    } catch { close(clientFD) }
                }
            }

            private func handleClient(fileDescriptor: Int32) throws {
                guard let sslContext else {
                    close(fileDescriptor)
                    return
                }
                guard let ssl = SSL_new(sslContext) else {
                    close(fileDescriptor)
                    throw POSIXError(.EIO)
                }
                defer {
                    unregisterActiveConnection(fileDescriptor)
                    SSL_shutdown(ssl)
                    SSL_free(ssl)
                    close(fileDescriptor)
                }

                SSL_set_fd(ssl, fileDescriptor)
                guard SSL_accept(ssl) == 1 else { throw POSIXError(.EACCES) }
                var requestBuffer = Data()
                while true {
                    guard let requestData = try Self.readTLSRequestLine(ssl: ssl, buffer: &requestBuffer) else { return }
                    let requestReceivedUptime = DispatchTime.now().uptimeNanoseconds
                    let request: SpacesDeviceAPIRequest
                    do { request = try SpacesDeviceAPICodec.decodeRequest(requestData) } catch {
                        try Self.writeTLSResponse(
                            try SpacesDeviceAPICodec.encodeResponseLine(
                                .init(ok: false, message: String(describing: error), errorCode: SpacesDeviceAPIServer.errorCode(for: error))), ssl: ssl)
                        return
                    }
                    logRequestPerformance(
                        name: "request_line_received", request: request, emittedUptimeNanoseconds: requestReceivedUptime, count: requestData.count,
                        fileDescriptor: fileDescriptor)

                    if request.command.isSubscriptionCommand {
                        let action = try server.syncOnQueue {
                            try server.authorize(request)
                            return try server.prepareLinuxSubscribe(request)
                        }
                        switch action {
                        case .response(let response):
                            let responseLine = try SpacesDeviceAPICodec.encodeResponseLine(response)
                            try writeLoggedTLSResponse(
                                responseLine, ssl: ssl, request: request, responseOK: response.ok, fileDescriptor: fileDescriptor)
                        case .finalPayload(let payload):
                            let payloadLine = try GhosttyRemoteSessionStateCodec.encodeLine(payload)
                            try writeLoggedTLSResponse(payloadLine, ssl: ssl, request: request, responseOK: true, fileDescriptor: fileDescriptor)
                        case .relay(let subscription):
                            registerActiveConnection(fileDescriptor, installationID: subscription.installationID)
                            try server.relayLinuxSubscription(subscription, ssl: ssl)
                        }
                        return
                    }

                    let response: SpacesDeviceAPIResponse
                    do {
                        response = try server.syncOnQueue {
                            try server.authorize(request)
                            return try server.handleRequest(request, peerID: "linux:\(fileDescriptor)")
                        }
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                        response = SpacesDeviceAPIResponse(ok: false, message: message, errorCode: SpacesDeviceAPIServer.errorCode(for: error))
                    }
                    let responseLine = try SpacesDeviceAPICodec.encodeResponseLine(response)
                    try writeLoggedTLSResponse(responseLine, ssl: ssl, request: request, responseOK: response.ok, fileDescriptor: fileDescriptor)
                    if !response.ok, response.errorCode == .unauthorized { return }
                }
            }

            private func writeLoggedTLSResponse(
                _ data: Data, ssl: OpaquePointer, request: SpacesDeviceAPIRequest, responseOK: Bool, fileDescriptor: Int32
            ) throws {
                let startedAt = Date()
                let attributes = requestAttributes(request, fileDescriptor: fileDescriptor, extra: ["ok": responseOK ? "1" : "0"])
                if let sessionID = request.sessionID {
                    server.logDeviceAPIPerformance(
                        sessionID: sessionID, name: "request_response_write_begin", count: data.count, attributes: attributes)
                }
                try Self.writeTLSResponse(data, ssl: ssl)
                if let sessionID = request.sessionID {
                    server.logDeviceAPIPerformance(
                        sessionID: sessionID, name: "request_response_write_end", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                        count: data.count, attributes: attributes)
                }
            }

            private func logRequestPerformance(
                name: String, request: SpacesDeviceAPIRequest, emittedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
                elapsedMS: Int? = nil, count: Int? = nil, fileDescriptor: Int32
            ) {
                guard let sessionID = request.sessionID else { return }
                server.logDeviceAPIPerformance(
                    sessionID: sessionID, name: name, emittedUptimeNanoseconds: emittedUptimeNanoseconds, elapsedMS: elapsedMS, count: count,
                    attributes: requestAttributes(request, fileDescriptor: fileDescriptor))
            }

            private func requestAttributes(_ request: SpacesDeviceAPIRequest, fileDescriptor: Int32, extra: [String: String] = [:]) -> [String:
                String]
            {
                var attributes: [String: String] = [
                    "command": request.commandName, "peer": "linux:\(fileDescriptor)", "transport": "linux_tls",
                    "client_id": request.clientID ?? request.clientApp?.installationID ?? "nil",
                ]
                for (key, value) in extra { attributes[key] = value }
                return attributes
            }

            private static func makeSSLContext(identity: TerminalServiceTLSIdentity) throws -> OpaquePointer {
                OPENSSL_init_ssl(0, nil)
                guard let method = TLS_server_method(), let context = SSL_CTX_new(method) else { throw POSIXError(.EIO) }
                guard spaces_SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) == 1 else {
                    SSL_CTX_free(context)
                    throw POSIXError(.EIO)
                }
                guard SSL_CTX_use_certificate_file(context, identity.certificatePath, SSL_FILETYPE_PEM) == 1 else {
                    SSL_CTX_free(context)
                    throw POSIXError(.EIO)
                }
                guard SSL_CTX_use_PrivateKey_file(context, identity.privateKeyPath, SSL_FILETYPE_PEM) == 1 else {
                    SSL_CTX_free(context)
                    throw POSIXError(.EIO)
                }
                guard SSL_CTX_check_private_key(context) == 1 else {
                    SSL_CTX_free(context)
                    throw POSIXError(.EIO)
                }
                return context
            }

            private static func makeListenSocket(host: String, port: Int) throws -> Int32 {
                let socketFD = socket(AF_INET, streamSocketType, 0)
                guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                var yes: Int32 = 1
                setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(UInt16(port).bigEndian)
                if SpacesDeviceAPIDefaults.isWildcardHost(host) {
                    address.sin_addr = in_addr(s_addr: in_addr_t(0))
                } else {
                    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                        close(socketFD)
                        throw POSIXError(.EADDRNOTAVAIL)
                    }
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
                guard listen(socketFD, 16) == 0 else {
                    let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                    close(socketFD)
                    throw POSIXError(code)
                }
                return socketFD
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

            private static func readTLSRequestLine(ssl: OpaquePointer, buffer data: inout Data) throws -> Data? {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    if let newlineIndex = data.firstIndex(of: 0x0A) {
                        let requestData = Data(data.prefix(upTo: newlineIndex))
                        data.removeSubrange(data.startIndex...newlineIndex)
                        return requestData
                    }
                    let count = SSL_read(ssl, &buffer, Int32(buffer.count))
                    if count > 0 {
                        data.append(buffer, count: Int(count))
                        continue
                    }
                    let error = SSL_get_error(ssl, count)
                    if error == SSL_ERROR_ZERO_RETURN {
                        guard !data.isEmpty else { return nil }
                        defer { data.removeAll(keepingCapacity: true) }
                        return data
                    }
                    throw POSIXError(.EIO)
                }
            }

            fileprivate static func writeTLSResponse(_ data: Data, ssl: OpaquePointer) throws {
                try data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    var bytesRemaining = rawBuffer.count
                    var offset = 0
                    while bytesRemaining > 0 {
                        let chunkSize = min(bytesRemaining, Int(Int32.max))
                        let written = SSL_write(ssl, baseAddress.advanced(by: offset), Int32(chunkSize))
                        guard written > 0 else { throw POSIXError(.EIO) }
                        bytesRemaining -= Int(written)
                        offset += Int(written)
                    }
                }
            }

            private func registerActiveConnection(_ fileDescriptor: Int32, installationID: String) {
                activeConnectionLock.lock()
                activeConnectionsByFD[fileDescriptor] = installationID
                activeConnectionLock.unlock()
            }

            private func unregisterActiveConnection(_ fileDescriptor: Int32) {
                activeConnectionLock.lock()
                activeConnectionsByFD.removeValue(forKey: fileDescriptor)
                activeConnectionLock.unlock()
            }

            private func closeActiveConnections(where shouldClose: (String) -> Bool) {
                activeConnectionLock.lock()
                let fileDescriptors = activeConnectionsByFD.filter { shouldClose($0.value) }.map(\.key)
                activeConnectionLock.unlock()
                for fileDescriptor in fileDescriptors {
                    SpacesDeviceAPIServer.shutdownSocket(fileDescriptor, how: SpacesDeviceAPIServer.shutdownReadWrite)
                }
            }

            private static func setNonBlocking(_ fileDescriptor: Int32) throws {
                let currentFlags = fcntl(fileDescriptor, F_GETFL)
                guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }

            private static func setBlocking(_ fileDescriptor: Int32) throws {
                let currentFlags = fcntl(fileDescriptor, F_GETFL)
                guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard fcntl(fileDescriptor, F_SETFL, currentFlags & ~O_NONBLOCK) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }

            private static func setCloseOnExec(_ fileDescriptor: Int32) throws {
                let currentFlags = fcntl(fileDescriptor, F_GETFD)
                guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard fcntl(fileDescriptor, F_SETFD, currentFlags | FD_CLOEXEC) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }

            private static func setSocketTimeout(_ fileDescriptor: Int32, seconds: TimeInterval) {
                var value = timeval(tv_sec: Int(seconds.rounded(.down)), tv_usec: 0)
                setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
            }

            private static var streamSocketType: Int32 { Int32(SOCK_STREAM.rawValue) }
        }
    #endif

    private let host: String
    private let port: Int
    private let identity: TerminalServiceTLSIdentity
    private let pairingCoordinator: SpacesDevicePairingCoordinator
    private let pairingStore: any SpacesDevicePairingStoreProtocol
    private let onPairingSucceeded: (@Sendable (SpacesDeviceClientApp) -> Void)?
    private let builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator?
    private let builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher?
    /// Frozen-core restart hook. Invoked for `.requestDaemonRestart`; the daemon process exits and
    /// is respawned by launchd `KeepAlive` / systemd `Restart=always` from the updated binary.
    private let onRestartRequested: (@Sendable () -> Void)?
    private let overviewLoaderForTesting: (@Sendable (SpacesDeviceClientApp?) throws -> SpacesDeviceOverviewPayload)?
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private let terminalLinkTransferAuthorizationTTL: TimeInterval
    private let traceEnabled = ProcessInfo.processInfo.environment["SPACES_DEVICE_API_TRACE"] == "1"
    // Device-overview push (cross-platform): a unix-socket producer that both
    // transports relay, fed by database-change notifications. Owned here so the
    // push logic is shared by the macOS and Linux Device API transports.
    private var overviewStreamServer: DeviceOverviewStreamServer?
    private let overviewStreamQueue = DispatchQueue(label: "spaces.device.overview.stream")
    private var overviewDatabaseChangeObserver: NSObjectProtocol?
    private var overviewDistributedChangeObserver: NSObjectProtocol?
    private var overviewTerminalChangeObserver: NSObjectProtocol?
    private var overviewTerminalDistributedObserver: NSObjectProtocol?
    private var overviewBroadcastScheduled = false

    #if canImport(Network) && canImport(Security)
        private let networkShaper: NetworkShaper
        private var listener: NWListener?
        private var requestConnections: [ObjectIdentifier: RequestConnection] = [:]
        private var streamRelays: [ObjectIdentifier: StreamRelay] = [:]
        private var streamRelaysClosingAfterFinalSend: Set<ObjectIdentifier> = []
    #elseif os(Linux) && canImport(OpenSSL)
        private var linuxServer: LinuxServer?
    #endif
    private var terminalLinkTransferAuthorizations: [String: TerminalLinkTransferAuthorization] = [:]
    private var running = false
    private var acceptingRequests = false

    public init(
        host: String, port: Int, identity: TerminalServiceTLSIdentity,
        pairingCoordinator: SpacesDevicePairingCoordinator = SpacesDevicePairingCoordinator(), pairingStore: SpacesDevicePairingStore? = nil,
        onPairingSucceeded: (@Sendable (SpacesDeviceClientApp) -> Void)? = nil,
        builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator? = nil,
        builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil, onRestartRequested: (@Sendable () -> Void)? = nil
    ) throws {
        self.host = host
        self.port = port
        self.identity = identity
        self.pairingCoordinator = pairingCoordinator
        self.onPairingSucceeded = onPairingSucceeded
        self.builtInTerminalSessionTerminator = builtInTerminalSessionTerminator
        self.builtInTerminalSessionLauncher = builtInTerminalSessionLauncher
        self.onRestartRequested = onRestartRequested
        overviewLoaderForTesting = nil
        if let pairingStore { self.pairingStore = pairingStore } else { self.pairingStore = try SpacesDevicePairingStore() }
        #if canImport(Network) && canImport(Security)
            networkShaper = NetworkShaper()
        #endif
        terminalLinkTransferAuthorizationTTL = Self.defaultTerminalLinkTransferAuthorizationTTL
        queue = DispatchQueue(label: "spaces.device.api")
        queue.setSpecific(key: queueKey, value: ())
    }

    init(
        host: String, port: Int, identity: TerminalServiceTLSIdentity,
        pairingCoordinator: SpacesDevicePairingCoordinator = SpacesDevicePairingCoordinator(),
        pairingStoreProtocol: any SpacesDevicePairingStoreProtocol, onPairingSucceeded: (@Sendable (SpacesDeviceClientApp) -> Void)? = nil,
        networkEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator? = nil,
        builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil,
        onRestartRequested: (@Sendable () -> Void)? = nil,
        terminalLinkTransferAuthorizationTTL: TimeInterval = SpacesDeviceAPIServer.defaultTerminalLinkTransferAuthorizationTTL,
        overviewLoaderForTesting: (@Sendable (SpacesDeviceClientApp?) throws -> SpacesDeviceOverviewPayload)? = nil
    ) {
        self.host = host
        self.port = port
        self.identity = identity
        self.pairingCoordinator = pairingCoordinator
        self.pairingStore = pairingStoreProtocol
        self.onPairingSucceeded = onPairingSucceeded
        self.builtInTerminalSessionTerminator = builtInTerminalSessionTerminator
        self.builtInTerminalSessionLauncher = builtInTerminalSessionLauncher
        self.onRestartRequested = onRestartRequested
        self.overviewLoaderForTesting = overviewLoaderForTesting
        #if canImport(Network) && canImport(Security)
            networkShaper = NetworkShaper(environment: networkEnvironment)
        #endif
        self.terminalLinkTransferAuthorizationTTL = terminalLinkTransferAuthorizationTTL
        queue = DispatchQueue(label: "spaces.device.api")
        queue.setSpecific(key: queueKey, value: ())
    }

    public private(set) var listeningPort: Int = 0

    public var certificateFingerprint: String { identity.certificateFingerprint }

    public var isRunning: Bool {
        stateLock.lock()
        let value = running
        stateLock.unlock()
        return value
    }

    var requestConnectionCountForTesting: Int {
        #if canImport(Network) && canImport(Security)
            if DispatchQueue.getSpecific(key: queueKey) != nil { return requestConnections.count }
            return queue.sync { requestConnections.count }
        #else
            return 0
        #endif
    }

    func terminalLinkTransferAuthorizationExpirationForTesting(linkID: String) -> Date? {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return terminalLinkTransferAuthorizations[linkID]?.expiresAt }
        return queue.sync { terminalLinkTransferAuthorizations[linkID]?.expiresAt }
    }

    public func start(timeout: TimeInterval = 5) throws {
        #if canImport(Network) && canImport(Security)
            let nwPort = try Self.nwPort(port)
            let tlsOptions = NWProtocolTLS.Options()
            let securityOptions = tlsOptions.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
            sec_protocol_options_set_peer_authentication_required(securityOptions, false)
            guard let secIdentity = sec_identity_create(identity.identity) else { throw TerminalServiceTLSError.identityImportFailed(errSecParam) }
            sec_protocol_options_set_local_identity(securityOptions, secIdentity)
            let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            if !SpacesDeviceAPIDefaults.isWildcardHost(host) {
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
            }

            let createdListener = try NWListener(using: parameters, on: nwPort)
            let startup = StartupSignal()

            createdListener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                guard self.acceptingRequests else {
                    connection.cancel()
                    return
                }
                self.trace("request_connection_accept peer=\(String(describing: connection.endpoint))")
                let requestConnection = RequestConnection(connection: connection, server: self)
                self.requestConnections[ObjectIdentifier(connection)] = requestConnection
                requestConnection.start(on: self.queue)
            }
            createdListener.stateUpdateHandler = { [weak self, weak createdListener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listeningPort = Int(createdListener?.port?.rawValue ?? UInt16(self.port))
                    self.acceptingRequests = true
                    self.setRunning(true)
                    startup.signal(.success(()))
                case .failed(let error):
                    self.acceptingRequests = false
                    self.setRunning(false)
                    startup.signal(.failure(error))
                case .cancelled:
                    self.acceptingRequests = false
                    self.setRunning(false)
                default: break
                }
            }
            listener = createdListener
            createdListener.start(queue: queue)

            if case .failure(let error) = startup.wait(timeout: timeout) ?? .failure(POSIXError(.ETIMEDOUT)) {
                createdListener.stateUpdateHandler = nil
                createdListener.newConnectionHandler = nil
                createdListener.cancel()
                throw error
            }
        #elseif os(Linux) && canImport(OpenSSL)
            let createdServer = LinuxServer(host: host, port: port, identity: identity, server: self, queue: queue)
            try createdServer.start(timeout: timeout)
            linuxServer = createdServer
            listeningPort = createdServer.listeningPort
            acceptingRequests = true
            setRunning(true)
        #else
            throw POSIXError(.ENOTSUP)
        #endif
        startOverviewStreamServer()
    }

    /// Starts the device-overview producer and observes database changes so each
    /// committed write pushes a fresh overview to subscribed clients. Cross-platform
    /// (POSIX socket + NotificationCenter), with the macOS distributed observer
    /// added so cross-process writes (the CLI sharing this profile) are caught too.
    /// Linux cross-process writes are bridged by spacesd into the same in-process
    /// notification.
    private func startOverviewStreamServer() {
        guard overviewStreamServer == nil else { return }
        let server = DeviceOverviewStreamServer(
            socketPath: (try? TerminalServicePaths.deviceOverviewSocketPath()) ?? "", queue: overviewStreamQueue,
            lineProvider: { [weak self] in
                guard let self, let payload = try? self.loadOverview() else { return nil }
                return try? SpacesDeviceOverviewStreamCodec.encodeLine(payload)
            })
        do { try server.start() } catch {
            trace("overview_stream_server_start_error error=\(error)")
            return
        }
        overviewStreamServer = server
        overviewDatabaseChangeObserver = NotificationCenter.default.addObserver(forName: IPCNotification.databaseDidChange, object: nil, queue: nil) {
            [weak self] _ in self?.scheduleOverviewBroadcast()
        }
        // Terminal runtime/title/exit state lives outside the database, so it does not
        // raise databaseDidChange. Observe the dedicated terminal-overview signal so
        // those changes still push a fresh overview to subscribers.
        overviewTerminalChangeObserver = NotificationCenter.default.addObserver(forName: TerminalOverviewSignal.name, object: nil, queue: nil) {
            [weak self] _ in self?.scheduleOverviewBroadcast()
        }
        #if canImport(Network) && canImport(Security)
            overviewDistributedChangeObserver = DistributedNotificationCenter.default().addObserver(
                forName: IPCNotification.databaseDidChange, object: try? IPCNotification.currentObject(), queue: nil
            ) { [weak self] _ in self?.scheduleOverviewBroadcast() }
            // A terminal session hosted in another process (the app) signals overview
            // changes profile-scoped across processes; catch those here too.
            overviewTerminalDistributedObserver = DistributedNotificationCenter.default().addObserver(
                forName: TerminalOverviewSignal.name, object: try? IPCNotification.currentObject(), queue: nil
            ) { [weak self] _ in self?.scheduleOverviewBroadcast() }
        #endif
    }

    private func stopOverviewStreamServer() {
        if let overviewDatabaseChangeObserver {
            NotificationCenter.default.removeObserver(overviewDatabaseChangeObserver)
            self.overviewDatabaseChangeObserver = nil
        }
        if let overviewTerminalChangeObserver {
            NotificationCenter.default.removeObserver(overviewTerminalChangeObserver)
            self.overviewTerminalChangeObserver = nil
        }
        if let overviewDistributedChangeObserver {
            #if canImport(Network) && canImport(Security)
                DistributedNotificationCenter.default().removeObserver(overviewDistributedChangeObserver)
            #endif
            self.overviewDistributedChangeObserver = nil
        }
        if let overviewTerminalDistributedObserver {
            #if canImport(Network) && canImport(Security)
                DistributedNotificationCenter.default().removeObserver(overviewTerminalDistributedObserver)
            #endif
            self.overviewTerminalDistributedObserver = nil
        }
        overviewStreamServer?.stop()
        overviewStreamServer = nil
    }

    /// Coalesces database-change bursts into one overview rebuild + push.
    private func scheduleOverviewBroadcast() {
        overviewStreamQueue.async { [weak self] in
            guard let self, !self.overviewBroadcastScheduled else { return }
            self.overviewBroadcastScheduled = true
            self.overviewStreamQueue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                guard let self else { return }
                self.overviewBroadcastScheduled = false
                self.overviewStreamServer?.broadcast()
            }
        }
    }

    public func stop() { queue.async { self.stopOnQueue() } }

    func listPairedDevices() throws -> [SpacesDevicePairedClient] { try syncOnQueue { try self.pairingStore.listDevices() } }

    func revokePairing(installationID: String) throws -> [SpacesDevicePairedClient] {
        try syncOnQueue {
            try self.pairingStore.revoke(installationID: installationID)
            self.closeStreamRelaysOnQueue(forInstallationID: installationID)
            return try self.pairingStore.listDevices()
        }
    }

    func resetPairingsAndStop() throws {
        try syncOnQueue {
            self.stopOnQueue()
            try self.pairingStore.removeAll()
        }
    }

    public func closeStreamRelays(forInstallationID installationID: String) {
        let normalizedID = installationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }

        if DispatchQueue.getSpecific(key: queueKey) != nil {
            closeStreamRelaysOnQueue(forInstallationID: normalizedID)
        } else {
            queue.async { self.closeStreamRelaysOnQueue(forInstallationID: normalizedID) }
        }
    }

    public func openPairingWindow(host linkHost: String, name: String, duration: TimeInterval = SpacesDevicePairingCoordinator.defaultWindowDuration)
        -> SpacesDevicePairingWindow
    {
        pairingCoordinator.openWindow(
            host: linkHost, port: listeningPort > 0 ? listeningPort : port, certificateFingerprint: identity.certificateFingerprint, name: name,
            protocolVersion: SpacesWireProtocol.version, appVersion: AppVersion.short, duration: duration)
    }

    public func openPairingWindow(
        host linkHost: String, name: String, duration: TimeInterval = SpacesDevicePairingCoordinator.defaultWindowDuration, code: String,
        nonce: String? = nil
    ) -> SpacesDevicePairingWindow {
        pairingCoordinator.openWindow(
            host: linkHost, port: listeningPort > 0 ? listeningPort : port, certificateFingerprint: identity.certificateFingerprint, name: name,
            protocolVersion: SpacesWireProtocol.version, appVersion: AppVersion.short, duration: duration, code: code, nonce: nonce)
    }

    public func pairingWindowSnapshot() -> SpacesDevicePairingWindowSnapshot? { pairingCoordinator.snapshot() }

    /// Per-request database access shared across a single request's handler,
    /// `refreshedMutationResponse`, and overview build so one request pays a single
    /// `SQLiteStore` open (schema check + integrity check) instead of two or three.
    ///
    /// The store opens lazily on first use so commands that never touch the database
    /// (ping, pairing, terminal control, directory listing, terminal-link chunk reads,
    /// and the conditional non-file `resolveTerminalLink` path) pay no open.
    ///
    /// Confinement: a context is created inside `handleRequest`, which runs only on the
    /// serial `spaces.device.api` queue, and it never escapes that request's stack frame.
    /// It must not be stored on the server or captured into an escaping closure — the
    /// off-request paths (overview-stream `lineProvider`, `loadDaemonStatus`, and the two
    /// background launch/setup paths) each open their own store on their own queue.
    private final class RequestContext {
        private let orchestratorFactory: (SQLiteStore) -> WorkspaceOrchestrator
        private var openedStore: SQLiteStore?
        private var openedOrchestrator: WorkspaceOrchestrator?

        init(orchestratorFactory: @escaping (SQLiteStore) -> WorkspaceOrchestrator) { self.orchestratorFactory = orchestratorFactory }

        func store() throws -> SQLiteStore {
            if let openedStore { return openedStore }
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            openedStore = store
            return store
        }

        func orchestrator() throws -> WorkspaceOrchestrator {
            if let openedOrchestrator { return openedOrchestrator }
            let orchestrator = orchestratorFactory(try store())
            openedOrchestrator = orchestrator
            return orchestrator
        }
    }

    private func handleRequest(_ request: SpacesDeviceAPIRequest, peerID: String) throws -> SpacesDeviceAPIResponse {
        let context = RequestContext { [self] store in deviceOrchestrator(store: store) }
        switch request.command {
        case .pair(let payload):
            guard let clientApp = request.clientApp else {
                return SpacesDeviceAPIResponse(ok: false, message: SpacesDevicePairingError.missingClientApp.localizedDescription)
            }
            // Version-gate before validating the code so an incompatible client never consumes the
            // one-time pairing window. A missing clientProtocolVersion reads as an incompatible (too
            // old) client. This runs pre-authentication, so it discloses the daemon's app version.
            if let incompatibility = Self.pairingVersionRejection(clientProtocolVersion: payload.clientProtocolVersion) {
                return SpacesDeviceAPIResponse(ok: false, message: incompatibility)
            }
            try pairingStore.validate(clientApp: clientApp)
            try pairingCoordinator.validate(code: payload.pairingCode, nonce: payload.pairingNonce, peerID: peerID)
            // A fresh pairing always mints a new token; there is no prior token to preserve.
            let issuedToken = try pairingStore.issueToken(for: clientApp, presentedToken: nil)
            onPairingSucceeded?(clientApp)
            return SpacesDeviceAPIResponse(ok: true, message: "Paired iOS client.", result: .issuedAuthToken(.init(authToken: issuedToken)))
        case .ping: return SpacesDeviceAPIResponse(ok: true, message: "pong")
        case .daemonStatus: return SpacesDeviceAPIResponse(ok: true, message: "Loaded daemon status.", result: .daemonStatus(try loadDaemonStatus()))
        case .requestDaemonRestart:
            guard let onRestartRequested else {
                return SpacesDeviceAPIResponse(ok: false, message: "This daemon cannot restart itself.", errorCode: .capabilityMissing)
            }
            onRestartRequested()
            return SpacesDeviceAPIResponse(ok: true, message: "spacesd is restarting.")
        case .overview:
            return SpacesDeviceAPIResponse(
                ok: true, message: "Loaded device overview.",
                result: .overview(try loadOverview(store: context.store(), clientApp: request.clientApp)))
        case .createProject(let payload): return try handleCreateProjectRequest(payload, context: context)
        case .previewGitProject(let payload): return try handleGitPreviewRequest(payload, context: context)
        case .deleteProject(let payload): return try handleDeleteProjectRequest(payload, context: context)
        case .importProject(let payload): return try handleImportProjectRequest(payload, context: context)
        case .exportProject(let payload): return try handleExportProjectRequest(payload, context: context)
        case .previewProject(let payload): return try handlePreviewProjectRequest(payload, context: context)
        case .listDirectories(let payload): return try handleListDirectoriesRequest(payload)
        case .workspaceCreateOptions(let payload): return try handleWorkspaceCreateOptionsRequest(payload, context: context)
        case .createWorkspace(let payload): return try handleCreateWorkspaceRequest(payload, context: context)
        case .launchWorkspace(let payload): return try handleLaunchWorkspaceRequest(payload, context: context)
        case .stopWorkspace(let payload): return try handleStopWorkspaceRequest(payload, context: context)
        case .restartWorkspace(let payload): return try handleRestartWorkspaceRequest(payload, context: context)
        case .archiveWorkspace(let payload): return try handleArchiveWorkspaceRequest(payload, context: context)
        case .runWorkspaceSetup(let payload): return try handleRunWorkspaceSetupRequest(payload, context: context)
        case .updateProjectConfig(let payload): return try handleUpdateProjectConfigRequest(payload, context: context)
        case .updateWorkspaceConfig(let payload): return try handleUpdateWorkspaceConfigRequest(payload, context: context)
        case .updateWorkspaceMetadata(let payload): return try handleUpdateWorkspaceMetadataRequest(payload, context: context)
        case .openWorkspaceTerminal(let payload): return try handleOpenWorkspaceTerminalRequest(payload, context: context)
        case .stopWorkspaceTerminal(let payload): return try handleStopWorkspaceTerminalRequest(payload, context: context)
        case .renameTerminalSession(let payload): return try handleRenameTerminalSessionRequest(payload, context: context)
        case .runWorkspaceProcess(let payload): return try handleRunWorkspaceProcessRequest(payload, context: context)
        case .stopWorkspaceProcess(let payload): return try handleStopWorkspaceProcessRequest(payload, context: context)
        case .restartWorkspaceProcess(let payload): return try handleRestartWorkspaceProcessRequest(payload, context: context)
        case .runCodingAgent(let payload): return try handleRunCodingAgentRequest(payload, context: context)
        case .stopCodingAgent(let payload): return try handleStopCodingAgentRequest(payload, context: context)
        case .restartCodingAgent(let payload): return try handleRestartCodingAgentRequest(payload, context: context)
        case .state(let payload): return try handleStateRequest(payload)
        case .terminalControl(let payload): return try handleTerminalControlRequest(payload)
        case .terminalPasteImage(let payload): return try handleTerminalPasteImageRequest(payload)
        case .sendTerminalInput(let payload): return try handleSendTerminalInputRequest(payload)
        case .tailTerminalOutput(let payload): return try handleTailTerminalOutputRequest(payload)
        case .resolveTerminalLink(let payload): return try handleResolveTerminalLinkRequest(payload, context: context)
        case .readTerminalLinkChunk(let payload): return try handleReadTerminalLinkChunkRequest(payload)
        case .subscribe, .subscribeDeviceOverview:
            return SpacesDeviceAPIResponse(ok: false, message: "Subscription requests must use the stream path.", errorCode: .misroutedRequest)
        }
    }

    private func authorize(_ request: SpacesDeviceAPIRequest) throws {
        guard !request.command.isPairingCommand else { return }
        do { try pairingStore.authorize(clientApp: request.clientApp, authToken: request.authToken) } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw NSError(domain: "SpacesDeviceAPIServer", code: 401, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// Maps a thrown error to its wire failure category at the top-level flatten points, where a typed
    /// error collapses into `(ok:false, message:)`. `authorize` and `resolvedRunningProcessID` rewrap
    /// failures as `NSError(domain: "SpacesDeviceAPIServer")` carrying the HTTP-like status in `code`,
    /// so those codes drive the mapping directly.
    static func errorCode(for error: any Error) -> SpacesDeviceErrorCode {
        let nsError = error as NSError
        if nsError.domain == "SpacesDeviceAPIServer" {
            switch nsError.code {
            case 401: return .unauthorized
            case 400: return .invalidArgument
            case 404: return .notFound
            default: return .internalError
            }
        }
        if error is SpacesDevicePairingError { return .unauthorized }
        if let workspaceError = error as? WorkspaceError {
            switch workspaceError {
            case .missingProject, .missingWorkspace, .missingTrackedWindow: return .notFound
            case .invalidArgument, .invalidWorkspace, .projectAlreadyExists, .workspaceAlreadyExists: return .invalidArgument
            case .gitCommandFailed, .dependencyMissing, .configError, .databaseMigrationFailed: return .internalError
            }
        }
        if error is DecodingError { return .invalidArgument }
        return .internalError
    }

    private func handleTerminalControlRequest(_ payload: SpacesDeviceTerminalControlRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = payload.sessionID
        let clientID = Self.normalizedClientID(payload.clientID)
        trace(
            "terminal_control_request source_session=\(sessionID) target_session=\(sessionID) client=\(clientID ?? payload.client?.id ?? "-") command=\(payload.action.rawValue)"
        )
        let terminalCommand = Self.terminalControlCommand(from: payload, clientID: clientID)
        if terminalCommand.requiresOwnerClientID, clientID == nil { return SpacesDeviceAPIResponse(ok: false, message: "Missing device client ID.", errorCode: .invalidArgument) }

        let startedAt = Date()
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not running.", errorCode: .sessionNotRunning)
        }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not available.", errorCode: .sessionNotAvailable)
        }

        let attributes: [String: String] = [
            "action": payload.action.rawValue, "client_id": clientID ?? "nil", "owner_epoch": payload.ownerEpoch.map(String.init) ?? "nil",
        ]
        let terminalRequest = TerminalControlRequest(command: terminalCommand)
        let dispatchStartedAt = Date()
        logDeviceAPIPerformance(sessionID: sessionID, name: "terminal_control_dispatch_begin", attributes: attributes)
        let response = try TerminalControlClient.send(request: terminalRequest, socketPath: paths.controlSocketPath)
        let dispatchMS = TerminalPerformance.elapsedMS(since: dispatchStartedAt)
        var responseAttributes = attributes
        responseAttributes["ok"] = response.ok ? "1" : "0"
        responseAttributes["control_socket_ms"] = String(dispatchMS)
        logDeviceAPIPerformance(sessionID: sessionID, name: "terminal_control_dispatch_end", elapsedMS: dispatchMS, attributes: responseAttributes)
        TerminalPerformance.logMetric(
            "device_api_\(payload.action.rawValue)", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: response.ok)
        let sessionState = response.ok && terminalCommand.includesSessionStateOnSuccess ? try? loadCurrentState(sessionID: sessionID) : nil
        responseAttributes["include_session_state"] = sessionState == nil ? "0" : "1"
        logDeviceAPIPerformance(
            sessionID: sessionID, name: "terminal_control_response_ready", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            attributes: responseAttributes)
        return SpacesDeviceAPIResponse(
            ok: response.ok, message: response.message, errorCode: response.errorCode, result: sessionState.map(SpacesDeviceAPIResult.terminalState))
    }

    private static func terminalControlCommand(from payload: SpacesDeviceTerminalControlRequest, clientID: String?) -> TerminalControlCommand {
        switch payload.action {
        case .attach:
            .attach(TerminalControlAttachPayload(client: payload.client, attachmentMode: payload.attachmentMode, appearance: payload.appearance))
        case .detach: .detach(TerminalControlClientPayload(clientID: clientID))
        case .heartbeat: .heartbeat(TerminalControlClientPayload(clientID: clientID))
        case .takeover: .takeover(TerminalControlClientPayload(clientID: clientID))
        case .send:
            .send(
                TerminalControlSendPayload(
                    text: payload.text, bytes: nil, clientID: clientID, ownerEpoch: payload.ownerEpoch, appendNewline: payload.appendNewline))
        case .key: .key(TerminalControlKeyPayload(key: payload.key, clientID: clientID, ownerEpoch: payload.ownerEpoch))
        case .clearScreen: .clearScreen(TerminalControlOwnerPayload(clientID: clientID, ownerEpoch: payload.ownerEpoch))
        case .resize:
            .resize(
                TerminalControlResizePayload(
                    clientID: clientID, columns: payload.columns, rows: payload.rows, ownerEpoch: payload.ownerEpoch,
                    resizeSerial: payload.resizeSerial))
        case .scroll:
            .scroll(
                TerminalControlScrollPayload(
                    clientID: clientID, ownerEpoch: payload.ownerEpoch, scrollHorizontal: payload.scrollHorizontal,
                    scrollVertical: payload.scrollVertical, scrollMods: payload.scrollMods))
        case .setAppearance: .setAppearance(TerminalControlSetAppearancePayload(clientID: clientID, appearance: payload.appearance))
        }
    }

    /// Agent-facing one-shot input: token-authorized like every command but deliberately not
    /// attachment- or owner-epoch-gated, because orchestrator agents write into sessions they never
    /// attach to or render. Mirrors the local profile `terminalSend` contract.
    private func handleSendTerminalInputRequest(_ payload: SpacesDeviceTerminalInputRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = payload.sessionID
        let hasText = payload.text != nil
        let hasBytes = payload.bytes != nil
        guard hasText || hasBytes else { return SpacesDeviceAPIResponse(ok: false, message: "text or bytes is required.", errorCode: .invalidArgument) }
        guard !(hasText && hasBytes) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Provide text or bytes, not both.", errorCode: .invalidArgument)
        }

        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not running.", errorCode: .sessionNotRunning)
        }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not available.", errorCode: .sessionNotAvailable)
        }
        let response = try TerminalControlClient.send(
            request: TerminalControlRequest(
                command: .send(
                    TerminalControlSendPayload(
                        text: payload.text, bytes: payload.bytes, clientID: nil, ownerEpoch: nil, appendNewline: payload.appendNewline))),
            socketPath: paths.controlSocketPath)
        return SpacesDeviceAPIResponse(ok: response.ok, message: response.message, errorCode: response.errorCode)
    }

    /// Agent-facing rendered tail of the session's output log, mirroring the local profile
    /// `terminalTail` contract (VT replay through `TerminalOutputTail`).
    private func handleTailTerminalOutputRequest(_ payload: SpacesDeviceTerminalTailRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = payload.sessionID
        let lineCount = max(payload.lines ?? 20, 1)
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.outputPath) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' has no output yet.", errorCode: .sessionNotAvailable)
        }
        let output = try TerminalOutputTail.tail(path: paths.outputPath, lineCount: lineCount)
        return SpacesDeviceAPIResponse(ok: true, message: "Read terminal output.", result: .terminalOutput(.init(text: output)))
    }

    private func handleTerminalPasteImageRequest(_ payload: SpacesDeviceTerminalPasteImageRequest) throws -> SpacesDeviceAPIResponse {
        let startedAt = Date()
        let sessionID = payload.sessionID
        let clientID = Self.normalizedClientID(payload.clientID)
        guard let clientID else { return SpacesDeviceAPIResponse(ok: false, message: "Missing device client ID.", errorCode: .invalidArgument) }
        guard !payload.imageData.isEmpty else {
            return SpacesDeviceAPIResponse(ok: false, message: "Missing image payload.", errorCode: .invalidArgument)
        }
        guard payload.imageData.count <= Self.terminalPasteImageMaxBytes else {
            return SpacesDeviceAPIResponse(ok: false, message: "Image payload exceeds the 10 MiB limit.", errorCode: .payloadTooLarge)
        }
        let fileExtension = Self.normalizedPasteImageExtension(payload.fileExtension)
        guard let fileExtension else {
            return SpacesDeviceAPIResponse(ok: false, message: "Unsupported image file extension.", errorCode: .unsupportedFormat)
        }

        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not running.", errorCode: .sessionNotRunning)
        }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not available.", errorCode: .sessionNotAvailable)
        }
        guard let snapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths),
            TerminalRemoteSessionStatePolicy.activeOwnerClientID(in: snapshot) == clientID
        else {
            return SpacesDeviceAPIResponse(
                ok: false, message: "Only the active owner can paste images into the terminal.", errorCode: .ownershipRejected)
        }
        if let ownerEpoch = (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))?.renderOwnerEpoch, ownerEpoch != payload.ownerEpoch
        {
            return SpacesDeviceAPIResponse(
                ok: false, message: "Ignoring stale owner epoch \(payload.ownerEpoch); current owner epoch is \(ownerEpoch).",
                errorCode: .ownershipRejected)
        }

        let remotePath = "/tmp/spaces-paste-\(UUID().uuidString).\(fileExtension)"
        try Self.writeUserOnlyPasteImage(payload.imageData, toPath: remotePath)
        let terminalRequest = TerminalControlRequest(
            command: .send(
                TerminalControlSendPayload(text: remotePath, bytes: nil, clientID: clientID, ownerEpoch: payload.ownerEpoch, appendNewline: false)))
        let response: TerminalControlResponse
        do { response = try TerminalControlClient.send(request: terminalRequest, socketPath: paths.controlSocketPath) } catch {
            try? FileManager.default.removeItem(atPath: remotePath)
            throw error
        }
        if !response.ok { try? FileManager.default.removeItem(atPath: remotePath) }
        TerminalPerformance.logMetric(
            "device_api_terminalPasteImage", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: response.ok, detail: "bytes=\(payload.imageData.count) extension=\(fileExtension)")
        return SpacesDeviceAPIResponse(ok: response.ok, message: response.ok ? "Pasted image path." : response.message)
    }

    private static func normalizedClientID(_ value: String?) -> String? {
        guard let clientID = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty else { return nil }
        return clientID
    }

    private static func normalizedPasteImageExtension(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines)).lowercased()
        guard !normalized.isEmpty, terminalPasteImageExtensions.contains(normalized) else { return nil }
        return normalized
    }

    private static func writeUserOnlyPasteImage(_ data: Data, toPath path: String) throws {
        let fileDescriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = write(fileDescriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                    guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += written
                }
            }
            close(fileDescriptor)
        } catch {
            close(fileDescriptor)
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }

    // Frozen-core daemon status: wire protocol numbers plus the restart-impact counts a daemon
    // restart would destroy. This standalone path runs its own store scan so it works even when the
    // rest of the protocol is incompatible (the only time a client issues it). The compatible steady
    // state never reaches here — the same status rides inline on the overview (see `loadOverview`).
    private func loadDaemonStatus() throws -> TerminalServiceDaemonStatus {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        var impact = RestartImpactCounts()
        for project in try store.projects() {
            for workspace in try store.workspaces(projectID: project.id, includeArchived: false) {
                impact.accumulate(
                    runningProcesses: try store.runningProcesses(workspaceID: workspace.id),
                    agentWindows: try store.agentWindows(workspaceID: workspace.id))
            }
        }
        let liveTerminals = (try? TerminalSessionCatalog.listLiveSessions().count) ?? 0
        return Self.makeDaemonStatus(activeSessionCount: liveTerminals, impact: impact)
    }

    /// Restart-impact tallies a daemon restart would destroy. Shared by the standalone frozen-core
    /// `loadDaemonStatus` and the inline status attached to the overview so both report the same
    /// counts from whichever scan already loaded the records.
    private struct RestartImpactCounts {
        var runningProcesses = 0
        var activeAgents = 0
        var waitingAgents = 0

        mutating func accumulate(runningProcesses processes: [RunningProcessRecord], agentWindows: [AgentWindowRecord]) {
            runningProcesses += processes.filter { $0.status == .running }.count
            for agent in agentWindows {
                switch agent.status {
                case .spinning: activeAgents += 1
                case .waiting: waitingAgents += 1
                case .idle, .done: break
                }
            }
        }
    }

    /// Returns a rejection message when a pairing client's wire-protocol version does not match this
    /// daemon's, or nil when it matches. Keeps the pairing gate symmetric with the client's
    /// pre-redeem check: whichever side is older is told to update.
    static func pairingVersionRejection(clientProtocolVersion: Int?) -> String? {
        let clientProtocolVersion = clientProtocolVersion ?? 0
        guard clientProtocolVersion != SpacesWireProtocol.version else { return nil }
        if clientProtocolVersion < SpacesWireProtocol.version {
            return "This device runs Spaces \(AppVersion.short); update Spaces on the pairing device to match, then pair again."
        }
        return "This device runs Spaces \(AppVersion.short), which is older than the pairing device; update Spaces on this device, then pair again."
    }

    private static func makeDaemonStatus(activeSessionCount: Int, impact: RestartImpactCounts) -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: AppVersion.current,
            artifactVersion: ProcessInfo.processInfo.environment["SPACESD_ARTIFACT_VERSION"].flatMap { $0.isEmpty ? nil : $0 },
            certificateFingerprint: nil, activeSessionCount: activeSessionCount, runningProcesses: impact.runningProcesses,
            activeAgents: impact.activeAgents, waitingAgents: impact.waitingAgents)
    }

    /// Builds the device overview. Request handlers pass their shared per-request `store` so a
    /// mutation reuses one store end-to-end; the off-request overview-stream `lineProvider` passes
    /// no store and opens its own on the `overviewStreamQueue`.
    private func loadOverview(store providedStore: SQLiteStore? = nil, clientApp: SpacesDeviceClientApp? = nil) throws -> SpacesDeviceOverviewPayload
    {
        if let overviewLoaderForTesting { return try overviewLoaderForTesting(clientApp) }
        let store = try providedStore ?? SQLiteStore(path: DatabaseLocator.defaultPath())
        let orchestrator = deviceOrchestrator(store: store)
        // The router port is a Mac-only concept (only the macOS client runs Caddy), so remote
        // daemons never seed one and this fallback yields the canonical `AppConfig.defaultRouterPort`.
        // The reported `assignedPort.url` is a client-facing host/origin identity; the Mac client
        // rewrites the port to its own live Caddy port before navigation.
        let routerPort = (try? orchestrator.appConfig().routerPort) ?? AppConfig.defaultRouterPort
        let projects = try store.projects()
        // Batch the plain per-workspace table reads into one full-table query each, grouped by
        // workspace, so building N descriptors costs a constant number of queries instead of O(N).
        // Each batch preserves the same ORDER BY and WHERE semantics as its per-workspace counterpart,
        // so the grouped values match `store.<x>(workspaceID:)` element-for-element.
        let runningProcessesByWorkspace = try store.runningProcessesByWorkspace()
        let agentWindowsByWorkspace = try store.agentWindowsByWorkspace()
        let windowsByWorkspace = try store.windowsByWorkspace()
        let portsByWorkspace = try store.workspacePortsNamedByWorkspace()
        let setupStateByWorkspace = try store.workspaceSetupStateByWorkspace()
        let workspaces = try projects.flatMap { project in
            try store.workspaces(projectID: project.id, includeArchived: false).map { workspace in
                let slug = SpacesProfile.workspaceHostSlug(
                    branch: workspace.branch, projectName: project.name, isGitRepo: project.isGitRepo, workspaceID: workspace.id)
                // `resolvedWorkspaceBrowserSessions` and `workspaceSettings` stay per-workspace on
                // purpose: they rebuild the workspace's env/runtime plan internally rather than reading a
                // single table, so batching them would require restructuring orchestrator env
                // construction (out of scope for this N+1 pass).
                let resolvedBrowserSessions = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
                let namedPorts = portsByWorkspace[workspace.id] ?? []
                return SpacesDeviceOverviewBuilder.WorkspaceDescriptor(
                    project: project, workspace: workspace, settings: try? orchestrator.workspaceSettings(workspaceID: workspace.id),
                    runningProcesses: runningProcessesByWorkspace[workspace.id] ?? [], agentWindows: agentWindowsByWorkspace[workspace.id] ?? [],
                    windows: windowsByWorkspace[workspace.id] ?? [],
                    assignedPorts: namedPorts.map {
                        SpacesDeviceAssignedPort(name: $0.name, port: $0.port, url: "http://\($0.name).\(slug).localhost:\(routerPort)")
                    },
                    environment: orchestrator.buildWorkspaceEnv(
                        project: project, workspace: workspace, namedPorts: namedPorts.map { (port: $0.port, name: $0.name) }),
                    resolvedBrowserSessions: resolvedBrowserSessions,
                    // Mirror `orchestrator.workspaceSetupState`, which returns a succeeded default when no
                    // `workspace_settings` row exists for the workspace.
                    setupState: setupStateByWorkspace[workspace.id]
                        ?? WorkspaceSetupState(status: .succeeded, errorMessage: nil, startedAt: nil, finishedAt: nil))
            }
        }
        let localSessions = try TerminalSessionCatalog.listLiveSessions()
        let sessions = mergedTerminalSessions(localSessions)
        let workspaceRows = loadWorkspaceTerminalRows(workspaces: workspaces, sessions: sessions, hasFinalRenderBySessionID: [:])
        // Reuse the records the overview already scanned to tally restart impact, so the inline
        // handshake costs no extra store work on the refresh hot path.
        var impact = RestartImpactCounts()
        for descriptor in workspaces { impact.accumulate(runningProcesses: descriptor.runningProcesses, agentWindows: descriptor.agentWindows) }
        let daemonStatus = Self.makeDaemonStatus(activeSessionCount: localSessions.count, impact: impact)
        return SpacesDeviceOverviewBuilder.build(
            projects: projects, workspaces: workspaces, workspaceRows: workspaceRows, liveSessions: sessions, daemonStatus: daemonStatus)
    }

    private func mergedTerminalSessions(_ sessions: [TerminalSessionCatalogEntry]) -> [TerminalSessionCatalogEntry] {
        var order: [String] = []
        var entriesByID: [String: TerminalSessionCatalogEntry] = [:]
        for session in sessions {
            if entriesByID[session.sessionID] == nil { order.append(session.sessionID) }
            entriesByID[session.sessionID] = session
        }
        return order.compactMap { entriesByID[$0] }
    }

    /// Builds the per-workspace terminal rows for the overview. The descriptors already carry the exact
    /// records this needs — `descriptor.runningProcesses`/`descriptor.agentWindows` are populated in
    /// `loadOverview` from the same store queries — so this reuses them instead of re-querying per
    /// workspace, which otherwise doubled the process/agent reads on the refresh hot path.
    private func loadWorkspaceTerminalRows(
        workspaces: [SpacesDeviceOverviewBuilder.WorkspaceDescriptor], sessions: [TerminalSessionCatalogEntry],
        hasFinalRenderBySessionID: [String: Bool]
    ) -> [SpacesDeviceOverviewBuilder.WorkspaceTerminalRow] {
        var rows: [SpacesDeviceOverviewBuilder.WorkspaceTerminalRow] = []
        var representedSessionIDs = Set<String>()
        let sessionsByID = Dictionary(sessions.map { ($0.sessionID, $0) }, uniquingKeysWith: { existing, _ in existing })
        for descriptor in workspaces {
            let processesBySlot = Dictionary(grouping: descriptor.runningProcesses, by: { processSlotKey($0) })
            for process in processesBySlot.values.compactMap(preferredProcessRecord).sorted(by: {
                $0.templateName.localizedStandardCompare($1.templateName) == .orderedAscending
            }) {
                guard process.terminalApp == TerminalHost.spaces.appName,
                    let sessionID = normalizedTerminalSessionID(process.terminalNativeID ?? process.terminalTrackingID)
                else { continue }
                guard representedSessionIDs.insert(sessionID).inserted else { continue }
                guard let entry = sessionsByID[sessionID] ?? terminalCatalogEntry(sessionID: sessionID) else { continue }
                rows.append(
                    SpacesDeviceOverviewBuilder.WorkspaceTerminalRow(
                        entry: entry, workspace: descriptor, title: process.templateName, rowKind: .process, rowSourceID: process.id,
                        hasFinalRender: hasFinalRenderBySessionID[sessionID] ?? terminalFinalRenderAvailable(sessionID: sessionID)))
            }

            let agentsBySlot = Dictionary(grouping: descriptor.agentWindows, by: { agentSlotKey($0) })
            for agent in agentsBySlot.values.compactMap(preferredAgentRecord).sorted(by: {
                ($0.label ?? "").localizedStandardCompare($1.label ?? "") == .orderedAscending
            }) {
                guard agent.provider == .spaces, let sessionID = normalizedTerminalSessionID(agent.terminalNativeID ?? agent.terminalTrackingID)
                else { continue }
                guard representedSessionIDs.insert(sessionID).inserted else { continue }
                guard let entry = sessionsByID[sessionID] ?? terminalCatalogEntry(sessionID: sessionID) else { continue }
                rows.append(
                    SpacesDeviceOverviewBuilder.WorkspaceTerminalRow(
                        entry: entry, workspace: descriptor, title: agent.label ?? entry.effectiveTitle, rowKind: .agent, rowSourceID: agent.id,
                        hasFinalRender: hasFinalRenderBySessionID[sessionID] ?? terminalFinalRenderAvailable(sessionID: sessionID)))
            }
        }
        return rows
    }

    private func preferredProcessRecord(_ records: [RunningProcessRecord]) -> RunningProcessRecord? {
        records.max { lhs, rhs in
            let lhsRank = processRecordRank(lhs)
            let rhsRank = processRecordRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return (lhs.startedAt ?? lhs.exitedAt ?? "") < (rhs.startedAt ?? rhs.exitedAt ?? "")
        }
    }

    private func processRecordRank(_ record: RunningProcessRecord) -> Int {
        switch record.status {
        case .running: return 3
        case .idle: return 2
        case .exited: return 1
        }
    }

    private func preferredAgentRecord(_ records: [AgentWindowRecord]) -> AgentWindowRecord? {
        records.max { lhs, rhs in
            let lhsRank = agentRecordRank(lhs)
            let rhsRank = agentRecordRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private func agentRecordRank(_ record: AgentWindowRecord) -> Int {
        if record.provider == .spaces, let sessionID = normalizedTerminalSessionID(record.terminalNativeID ?? record.terminalTrackingID),
            let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            (try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.state.isInteractive == true
        {
            return 4
        }
        switch record.status {
        case .spinning: return 3
        case .waiting: return 2
        case .idle: return 1
        case .done: return 0
        }
    }

    private func processSlotKey(_ record: RunningProcessRecord) -> String {
        if let templateID = record.templateID?.trimmingCharacters(in: .whitespacesAndNewlines), !templateID.isEmpty {
            return "process-id:\(templateID)"
        }
        return "process:\(normalizedSlotName(record.templateName))"
    }

    private func agentSlotKey(_ record: AgentWindowRecord) -> String {
        if let claimedLauncherID = record.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines), !claimedLauncherID.isEmpty {
            return "agent-id:\(claimedLauncherID)"
        }
        let slotName = record.claimedLauncherName ?? record.label ?? record.id
        return "agent:\(normalizedSlotName(slotName))"
    }

    private func normalizedSlotName(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private func terminalCatalogEntry(sessionID: String, fileManager: FileManager = .default) -> TerminalSessionCatalogEntry? {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
            let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        else { return nil }
        guard !runtimeState.state.isInteractive || TerminalSessionCatalog.isInteractiveServiceAlive(for: runtimeState) else { return nil }
        let attachmentSnapshot = (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? .init()
        return TerminalSessionCatalogEntry(
            launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot, paths: paths,
            isControlAvailable: fileManager.fileExists(atPath: paths.controlSocketPath),
            isSubscriptionAvailable: fileManager.fileExists(atPath: paths.subscriptionSocketPath))
    }

    private func terminalFinalRenderAvailable(sessionID: String) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID) else { return false }
        return (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))?.renderSnapshot != nil
    }

    private func normalizedTerminalSessionID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func deviceOrchestrator(store: SQLiteStore) -> WorkspaceOrchestrator {
        WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: { _, _ in }, builtInTerminalSessionTerminator: builtInTerminalSessionTerminator,
            builtInTerminalSessionLauncher: builtInTerminalSessionLauncher)
    }

    private func finishReservedWorkspaceTerminalLaunchInBackground(_ reservation: WorkspaceOrchestrator.WorkspaceTerminalLaunchReservation) {
        let launcher = builtInTerminalSessionLauncher
        let terminator = builtInTerminalSessionTerminator
        let traceEnabled = traceEnabled
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let orchestrator = WorkspaceOrchestrator(
                    store: store, builtInTerminalWindowOpener: { _, _ in }, builtInTerminalSessionTerminator: terminator,
                    builtInTerminalSessionLauncher: launcher)
                try orchestrator.finishReservedWorkspaceTerminalLaunch(reservation)
            } catch {
                guard traceEnabled else { return }
                let message = String(describing: error).replacingOccurrences(of: "\n", with: "\\n")
                FileHandle.standardOutput.write(
                    Data(
                        "spaces-device-api-trace workspace_terminal_background_launch_error session=\(reservation.sessionID) error=\(message)\n".utf8)
                )
            }
        }
    }

    private func handleWorkspaceCreateOptionsRequest(_ request: SpacesDeviceWorkspaceCreateOptionsRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let store = try context.store()
        let orchestrator = try context.orchestrator()
        let projects = try store.projects().map {
            SpacesDeviceProjectSummary(id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let selectedProjectID = normalizedString(request.projectID) ?? projects.first?.id
        let branchOptions: [String]
        if let selectedProjectID, let project = try store.project(id: selectedProjectID), project.isGitRepo {
            branchOptions = try orchestrator.gitBranchOptions(projectID: selectedProjectID)
        } else {
            branchOptions = []
        }
        return SpacesDeviceAPIResponse(
            ok: true, message: "Loaded workspace create options.",
            result: .workspaceCreateOptions(
                SpacesDeviceWorkspaceCreateOptions(projects: projects, selectedProjectID: selectedProjectID, branchOptions: branchOptions)))
    }

    private func handlePreviewProjectRequest(_ request: SpacesDeviceProjectPreviewRequest, context: RequestContext) throws -> SpacesDeviceAPIResponse
    {
        guard let dir = normalizedString(request.dir) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Provide a project directory.", errorCode: .invalidArgument)
        }
        let project = try context.orchestrator().previewProject(dir: dir)
        let preview = SpacesDeviceProjectPreview(
            name: project.name, dir: project.dir, isGitRepo: project.isGitRepo, defaultBranch: project.defaultBranch,
            config: SpacesDeviceOverviewBuilder.projectConfig(from: project))
        return SpacesDeviceAPIResponse(ok: true, message: "Loaded project preview.", result: .projectPreview(preview))
    }

    private func handleListDirectoriesRequest(_ request: SpacesDeviceDirectoryListRequest) throws -> SpacesDeviceAPIResponse {
        let paths = Self.directorySuggestions(forPartialPath: request.path)
        return SpacesDeviceAPIResponse(
            ok: true, message: "Loaded directory suggestions.", result: .directorySuggestions(SpacesDeviceDirectorySuggestions(paths: paths)))
    }

    static func directorySuggestions(forPartialPath partial: String, limit: Int = 20) -> [String] {
        let trimmed = partial.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let usesTilde = trimmed == "~" || trimmed.hasPrefix("~/")
        let home = NSHomeDirectory()
        let parentDir: String
        let prefix: String
        if trimmed.hasSuffix("/") {
            parentDir = expanded
            prefix = ""
        } else {
            parentDir = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }
        let listDir = parentDir.isEmpty ? "/" : parentDir
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: listDir) else { return [] }
        let matches = entries.filter { name in
            guard !name.hasPrefix(".") || prefix.hasPrefix(".") else { return false }
            guard prefix.isEmpty || name.localizedCaseInsensitiveCompare(prefix) == .orderedSame || name.lowercased().hasPrefix(prefix.lowercased())
            else { return false }
            var isDirectory: ObjCBool = false
            let full = (listDir as NSString).appendingPathComponent(name)
            return fileManager.fileExists(atPath: full, isDirectory: &isDirectory) && isDirectory.boolValue
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return matches.prefix(limit).map { name in
            let full = (listDir as NSString).appendingPathComponent(name)
            if usesTilde, full == home { return "~" }
            if usesTilde, full.hasPrefix(home + "/") { return "~" + full.dropFirst(home.count) }
            return full
        }
    }

    private func handleCreateProjectRequest(_ request: SpacesDeviceProjectCreateRequest, context: RequestContext) throws -> SpacesDeviceAPIResponse {
        let projectDir = normalizedString(request.projectDir)
        let gitURL = normalizedString(request.gitURL)
        guard (projectDir == nil) != (gitURL == nil) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Provide exactly one project directory or Git URL.", errorCode: .invalidArgument)
        }

        let store = try context.store()
        let orchestrator = try context.orchestrator()
        let project: ProjectRecord
        if let projectDir {
            if let config = request.config {
                project = try orchestrator.addReviewedProject(dir: projectDir) { project in applyProjectConfig(config, to: &project) }
            } else {
                project = try orchestrator.addProject(dir: projectDir)
            }
        } else if let gitURL {
            // Clone the repository now (deferred from the add-project preview, which only fetched
            // spaces.yaml) and apply the client's reviewed config. addPreparedGitProject applies the
            // config unconditionally; addProject(gitURL:) would instead discard it in favor of the
            // repo's own spaces.yaml, dropping any edits the user made in the form.
            let prepared = try orchestrator.prepareGitProject(gitURL: gitURL, replaceExistingManagedDirectories: true)
            do {
                project = try orchestrator.addPreparedGitProject(prepared) { project in
                    if let config = request.config { applyProjectConfig(config, to: &project) }
                }
            } catch {
                try? orchestrator.discardPreparedGitProject(prepared)
                throw error
            }
        } else {
            return SpacesDeviceAPIResponse(ok: false, message: "Provide exactly one project directory or Git URL.", errorCode: .invalidArgument)
        }
        let defaultWorkspaceID = try store.workspaces(projectID: project.id, includeArchived: false).first(where: \.isDefault)?.id
        return try refreshedMutationResponse(
            context: context, message: "Created project '\(project.name)'.", projectID: project.id, workspaceID: defaultWorkspaceID)
    }

    /// Loads a git repository's `spaces.yaml` for the add-project preview by fetching only that single
    /// file (no clone), returning the detected config to populate the add form plus any managed
    /// directories a later Create would replace. The full clone is deferred to `createProject`.
    private func handleGitPreviewRequest(_ request: SpacesDeviceGitProjectPreviewRequest, context: RequestContext) throws -> SpacesDeviceAPIResponse {
        guard let gitURL = normalizedString(request.gitURL) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Git repository URL is required.", errorCode: .invalidArgument)
        }
        let preview = try context.orchestrator().previewGitProject(gitURL: gitURL)
        let candidates = preview.replacementCandidates.map { SpacesDeviceManagedDirectoryReplacementCandidate(kind: $0.kind.rawValue, path: $0.path) }
        return SpacesDeviceAPIResponse(
            ok: true, message: "Loaded git project preview.",
            result: .gitProjectPreview(
                SpacesDeviceGitProjectPreview(
                    config: SpacesDeviceOverviewBuilder.projectConfig(from: preview.project), replacementCandidates: candidates,
                    spacesYAMLFound: preview.spacesYAMLFound)))
    }

    private func handleDeleteProjectRequest(_ request: SpacesDeviceProjectReference, context: RequestContext) throws -> SpacesDeviceAPIResponse {
        let store = try context.store()
        let orchestrator = try context.orchestrator()
        guard let project = try store.project(id: request.projectID) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Project not found.", errorCode: .notFound)
        }
        try orchestrator.removeProject(dir: project.dir)
        return try refreshedMutationResponse(context: context, message: "Deleted project '\(project.name)'.")
    }

    private func handleImportProjectRequest(_ request: SpacesDeviceProjectImportRequest, context: RequestContext) throws -> SpacesDeviceAPIResponse {
        _ = try context.orchestrator().importSpacesYAML(projectID: request.projectID, updateAllWorkspaces: request.updateAllWorkspaces)
        return try refreshedMutationResponse(context: context, message: "Imported spaces.yaml.", projectID: request.projectID)
    }

    private func handleExportProjectRequest(_ request: SpacesDeviceProjectReference, context: RequestContext) throws -> SpacesDeviceAPIResponse {
        let url = try context.orchestrator().exportSpacesYAML(projectID: request.projectID)
        return try refreshedMutationResponse(context: context, message: "Exported spaces.yaml to \(url.path).", projectID: request.projectID)
    }

    private func handleCreateWorkspaceRequest(_ request: SpacesDeviceWorkspaceCreateRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let projectID = request.projectID
        let store = try context.store()
        let orchestrator = try context.orchestrator()
        let project = try store.project(id: projectID)
        // Create the workspace record and worktree synchronously, but leave the setup script
        // deferred (status `.pending`). A long-running setup script (e.g. a full build) would
        // otherwise block this request well past the client's request timeout, leaving the New
        // Workspace form stuck on "Creating...". Running setup in the background lets the response
        // return immediately so the UI can navigate to the workspace and stream its setup log.
        let workspace = try orchestrator.createWorkspace(
            projectID: projectID, branch: normalizedString(request.branch), baseBranch: normalizedString(request.baseBranch),
            directoryName: normalizedString(request.directoryName), runSetupScript: false, allowRemoteBranchLookup: true,
            allowExistingBranchReuse: request.allowExistingBranchReuse)
        if let notes = normalizedOptionalString(request.notes) { try orchestrator.updateWorkspaceNotes(workspaceID: workspace.id, notes: notes) }
        runWorkspaceSetupInBackground(workspaceID: workspace.id)
        let message = "Created workspace '\(workspace.displayName)'\(project.map { " in \($0.name)" } ?? "")."
        return try refreshedMutationResponse(context: context, message: message, workspaceID: workspace.id)
    }

    /// Runs a newly created workspace's deferred setup script on a background queue.
    ///
    /// Mirrors `finishReservedWorkspaceTerminalLaunchInBackground`: a fresh store and orchestrator
    /// are created inside the closure so only the `Sendable` workspace ID is captured. The setup
    /// state machine (`.pending` -> `.running` -> `.succeeded`/`.failed`) and the setup log are
    /// owned by `runWorkspaceSetup`, so progress and failures remain observable through the normal
    /// workspace setup detail UI without this request blocking on completion.
    private func runWorkspaceSetupInBackground(workspaceID: String) {
        let launcher = builtInTerminalSessionLauncher
        let terminator = builtInTerminalSessionTerminator
        let traceEnabled = traceEnabled
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
                let orchestrator = WorkspaceOrchestrator(
                    store: store, builtInTerminalWindowOpener: { _, _ in }, builtInTerminalSessionTerminator: terminator,
                    builtInTerminalSessionLauncher: launcher)
                try orchestrator.runWorkspaceSetup(workspaceID: workspaceID)
            } catch {
                guard traceEnabled else { return }
                let message = String(describing: error).replacingOccurrences(of: "\n", with: "\\n")
                FileHandle.standardOutput.write(
                    Data("spaces-device-api-trace workspace_background_setup_error workspace=\(workspaceID) error=\(message)\n".utf8))
            }
        }
    }

    private func handleLaunchWorkspaceRequest(_ request: SpacesDeviceWorkspaceLifecycleRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        try context.orchestrator().launchWorkspace(workspaceID: request.workspaceID)
        return try refreshedMutationResponse(context: context, message: "Launched workspace.", workspaceID: request.workspaceID)
    }

    private func handleStopWorkspaceRequest(_ request: SpacesDeviceWorkspaceLifecycleRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        _ = try context.orchestrator().stopWorkspace(workspaceID: request.workspaceID)
        return try refreshedMutationResponse(context: context, message: "Stopped workspace.", workspaceID: request.workspaceID)
    }

    private func handleRestartWorkspaceRequest(_ request: SpacesDeviceWorkspaceLifecycleRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        try context.orchestrator().upWorkspace(workspaceID: request.workspaceID, restartIfRunning: true, background: true)
        return try refreshedMutationResponse(context: context, message: "Restarted workspace.", workspaceID: request.workspaceID)
    }

    private func handleArchiveWorkspaceRequest(_ request: SpacesDeviceWorkspaceArchiveRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        _ = try context.orchestrator().archiveWorkspace(
            workspaceID: request.workspaceID, deleteLocalBranch: request.deleteLocalBranch, deleteRemoteBranch: request.deleteRemoteBranch)
        return try refreshedMutationResponse(context: context, message: "Archived workspace.", workspaceID: request.workspaceID)
    }

    private func handleRunWorkspaceSetupRequest(_ request: SpacesDeviceWorkspaceReference, context: RequestContext) throws -> SpacesDeviceAPIResponse
    {
        try context.orchestrator().runWorkspaceSetup(workspaceID: request.workspaceID)
        return try refreshedMutationResponse(context: context, message: "Ran workspace setup.", workspaceID: request.workspaceID)
    }

    private func handleUpdateProjectConfigRequest(_ request: SpacesDeviceProjectConfigUpdateRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        try context.orchestrator().updateProjectConfig(projectID: request.projectID, updateAllWorkspaces: request.updateAllWorkspaces) { config in
            config.setupScript = normalizedOptionalString(request.config.setupScript)
            config.stopScript = normalizedOptionalString(request.config.stopScript)
            config.ports = request.config.ports.map(workspacePort)
            config.processes = request.config.processes.map(workspaceProcess)
            config.browserSessions = request.config.browserSessions.map(workspaceBrowserSession)
            config.agentLaunchers = request.config.agentLaunchers.map(workspaceAgentLauncher)
        }
        return try refreshedMutationResponse(context: context, message: "Updated project settings.", projectID: request.projectID)
    }

    private func handleUpdateWorkspaceConfigRequest(_ request: SpacesDeviceWorkspaceConfigUpdateRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        try context.orchestrator().updateWorkspaceSettings(workspaceID: request.workspaceID) { config in
            config.stopScript = normalizedOptionalString(request.config.stopScript)
            config.ports = request.config.ports.map(workspacePort)
            config.processes = request.config.processes.map(workspaceProcess)
            config.browserSessions = request.config.browserSessions.map(workspaceBrowserSession)
            config.agentLaunchers = request.config.agentLaunchers.map(workspaceAgentLauncher)
        }
        return try refreshedMutationResponse(context: context, message: "Updated workspace settings.", workspaceID: request.workspaceID)
    }

    private func handleUpdateWorkspaceMetadataRequest(_ request: SpacesDeviceWorkspaceMetadataUpdateRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let orchestrator = try context.orchestrator()
        if request.updatesBranch {
            try orchestrator.updateWorkspaceMetadata(workspaceID: request.workspaceID, branch: normalizedString(request.branch) ?? "")
        }
        if request.updatesNotes || request.updatesHidden {
            try context.store().withTransaction {
                if request.updatesNotes {
                    try orchestrator.updateWorkspaceNotes(workspaceID: request.workspaceID, notes: normalizedOptionalString(request.notes))
                }
                if request.updatesHidden { try orchestrator.updateWorkspaceHidden(workspaceID: request.workspaceID, isHidden: request.isHidden == true) }
            }
        }
        return try refreshedMutationResponse(context: context, message: "Updated workspace metadata.", workspaceID: request.workspaceID)
    }

    private func handleOpenWorkspaceTerminalRequest(_ request: SpacesDeviceWorkspaceReference, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let orchestrator = try context.orchestrator()
        let reservation = try orchestrator.reserveWorkspaceTerminalLaunch(workspaceID: workspaceID)
        let response: SpacesDeviceAPIResponse
        do {
            response = try refreshedMutationResponse(
                context: context, message: "Opened workspace terminal.", workspaceID: workspaceID, sessionID: reservation.sessionID)
        } catch {
            orchestrator.cancelReservedWorkspaceTerminalLaunch(reservation)
            throw error
        }
        finishReservedWorkspaceTerminalLaunchInBackground(reservation)
        return response
    }

    private func handleStopWorkspaceTerminalRequest(_ request: SpacesDeviceWorkspaceTerminalRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let sessionID = request.sessionID
        guard try context.orchestrator().stopAdHocBuiltInTerminalSession(workspaceID: workspaceID, sessionID: sessionID) else {
            return try refreshedMutationResponse(context: context, message: "Workspace terminal was already stopped.", workspaceID: workspaceID)
        }
        return try refreshedMutationResponse(context: context, message: "Stopped workspace terminal.", workspaceID: workspaceID)
    }

    private func handleRenameTerminalSessionRequest(_ request: SpacesDeviceTerminalSessionRenameRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let sessionID = request.sessionID
        guard let title = normalizedString(request.title) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Provide a terminal session title.", errorCode: .invalidArgument)
        }
        guard try context.orchestrator().renameAdHocBuiltInTerminalSession(workspaceID: workspaceID, sessionID: sessionID, title: title) else {
            return SpacesDeviceAPIResponse(
                ok: false, message: "Terminal session '\(sessionID)' is not a renamable workspace terminal.", errorCode: .invalidArgument)
        }
        return try refreshedMutationResponse(context: context, message: "Renamed terminal session.", workspaceID: workspaceID, sessionID: sessionID)
    }

    private func handleRunWorkspaceProcessRequest(_ request: SpacesDeviceRunWorkspaceProcessRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let processKey = request.processKey
        let orchestrator = try context.orchestrator()
        let record =
            if let processTemplateID = normalizedString(request.processTemplateID) {
                try orchestrator.runConfiguredProcess(workspaceID: workspaceID, processTemplateID: processTemplateID, processKey: processKey)
            } else { try orchestrator.runConfiguredProcess(workspaceID: workspaceID, processKey: processKey) }
        return try refreshedMutationResponse(
            context: context, message: "Ran process '\(processKey)'.", workspaceID: workspaceID,
            sessionID: normalizedString(record.terminalNativeID ?? record.terminalTrackingID))
    }

    private func handleStopWorkspaceProcessRequest(_ request: SpacesDeviceWorkspaceProcessMutationRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let processID = try resolvedRunningProcessID(request: request, store: context.store())
        try context.orchestrator().stopWorkspaceProcess(workspaceID: workspaceID, processID: processID)
        return try refreshedMutationResponse(context: context, message: "Stopped process.", workspaceID: workspaceID)
    }

    private func handleRestartWorkspaceProcessRequest(_ request: SpacesDeviceWorkspaceProcessMutationRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let processID = try resolvedRunningProcessID(request: request, store: context.store())
        try context.orchestrator().restartWorkspaceProcess(workspaceID: workspaceID, processID: processID)
        return try refreshedMutationResponse(context: context, message: "Restarted process.", workspaceID: workspaceID)
    }

    private func handleRunCodingAgentRequest(_ request: SpacesDeviceRunCodingAgentRequest, context: RequestContext) throws -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        let agentName = request.agentName
        let orchestrator = try context.orchestrator()
        let record =
            if let agentLauncherID = normalizedString(request.agentLauncherID) {
                try orchestrator.launchAgentLauncher(workspaceID: workspaceID, launcherID: agentLauncherID)
            } else { try orchestrator.launchAgentLauncher(workspaceID: workspaceID, name: agentName) }
        return try refreshedMutationResponse(
            context: context, message: "Ran coding agent '\(agentName)'.", workspaceID: workspaceID,
            sessionID: normalizedString(record.terminalNativeID ?? record.terminalTrackingID))
    }

    private func handleStopCodingAgentRequest(_ request: SpacesDeviceCodingAgentMutationRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        guard let agentID = try resolvedAgentID(request: request, store: context.store()) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Missing coding agent ID.", errorCode: .invalidArgument)
        }
        try context.orchestrator().stopCodingAgent(workspaceID: workspaceID, agentID: agentID)
        return try refreshedMutationResponse(context: context, message: "Stopped coding agent.", workspaceID: workspaceID)
    }

    private func handleRestartCodingAgentRequest(_ request: SpacesDeviceCodingAgentMutationRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let workspaceID = request.workspaceID
        guard let agentID = try resolvedAgentID(request: request, store: context.store()) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Missing coding agent ID.", errorCode: .invalidArgument)
        }
        let record = try context.orchestrator().restartCodingAgent(workspaceID: workspaceID, agentID: agentID)
        return try refreshedMutationResponse(
            context: context, message: "Restarted coding agent.", workspaceID: workspaceID,
            sessionID: normalizedString(record.terminalNativeID ?? record.terminalTrackingID))
    }

    private func refreshedMutationResponse(
        context: RequestContext, message: String, projectID: String? = nil, workspaceID: String? = nil, sessionID: String? = nil
    ) throws -> SpacesDeviceAPIResponse {
        SpacesDeviceAPIResponse(
            ok: true, message: message,
            result: .mutation(
                SpacesDeviceMutationResult(
                    overview: try loadOverview(store: context.store()), projectID: projectID, workspaceID: workspaceID, sessionID: sessionID)))
    }

    private func resolvedRunningProcessID(request: SpacesDeviceWorkspaceProcessMutationRequest, store: SQLiteStore) throws -> String {
        let workspaceID = request.workspaceID
        if let processID = normalizedString(request.processID) { return processID }
        if let processTemplateID = normalizedString(request.processTemplateID),
            let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.templateID == processTemplateID })
        {
            return process.id
        }
        guard let processKey = normalizedString(request.processKey) else {
            throw NSError(domain: "SpacesDeviceAPIServer", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing process ID."])
        }
        let normalizedProcessKey = normalizedRowKey(processKey)
        guard
            let process = try store.runningProcesses(workspaceID: workspaceID).first(where: {
                normalizedRowKey($0.templateName) == normalizedProcessKey
            })
        else { throw NSError(domain: "SpacesDeviceAPIServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Running process not found."]) }
        return process.id
    }

    private func resolvedAgentID(request: SpacesDeviceCodingAgentMutationRequest, store: SQLiteStore) throws -> String? {
        let workspaceID = request.workspaceID
        if let agentID = normalizedString(request.agentID) { return agentID }
        if let agentLauncherID = normalizedString(request.agentLauncherID),
            let agentID = try store.agentWindows(workspaceID: workspaceID).first(where: { $0.claimedLauncherID == agentLauncherID })?.id
        {
            return agentID
        }
        guard let agentName = normalizedString(request.agentName) else { return nil }
        let normalizedAgentName = normalizedRowKey(agentName)
        return try store.agentWindows(workspaceID: workspaceID).first { normalizedRowKey($0.label ?? $0.claimedLauncherName) == normalizedAgentName }?
            .id
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func normalizedRowKey(_ value: String?) -> String { normalizedString(value)?.lowercased() ?? "" }

    private func workspacePort(_ port: SpacesDeviceServiceDefinition) -> ServiceDefinition { ServiceDefinition(id: port.id, name: port.name) }

    private func workspaceProcess(_ process: SpacesDeviceProcessTemplate) -> ProcessTemplate {
        ProcessTemplate(
            id: process.id, name: process.name, command: process.command, kind: process.kind,
            onExit: ProcessExitAction(rawValue: process.onExit) ?? .none)
    }

    private func workspaceBrowserSession(_ session: SpacesDeviceBrowserSession) -> BrowserSession {
        BrowserSession(name: session.name, url: session.url)
    }

    private func workspaceAgentLauncher(_ launcher: SpacesDeviceAgentLauncher) -> AgentLauncher {
        AgentLauncher(id: launcher.id, name: launcher.name, command: launcher.command)
    }

    private func applyProjectConfig(_ source: SpacesDeviceProjectConfig, to project: inout ProjectRecord) {
        project.setupScript = normalizedOptionalString(source.setupScript)
        project.stopScript = normalizedOptionalString(source.stopScript)
        project.ports = source.ports.map(workspacePort)
        project.processes = source.processes.map(workspaceProcess)
        project.browserSessions = source.browserSessions.map(workspaceBrowserSession)
        project.agentLaunchers = source.agentLaunchers.map(workspaceAgentLauncher)
    }

    private func handleStateRequest(_ request: SpacesDeviceTerminalSessionRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = request.sessionID
        let startedAt = Date()
        let payload = try loadCurrentState(sessionID: sessionID)
        TerminalPerformance.logMetric(
            "device_api_state", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
        return SpacesDeviceAPIResponse(ok: true, message: "Loaded terminal state.", result: .terminalState(payload))
    }

    private func handleResolveTerminalLinkRequest(_ request: SpacesDeviceTerminalLinkResolveRequest, context: RequestContext) throws
        -> SpacesDeviceAPIResponse
    {
        let sessionID = request.sessionID
        pruneTerminalLinkTransferAuthorizations(now: Date())
        let metadata: SpacesDeviceTerminalLinkMetadata
        if canResolveTerminalLinkWithoutLocalState(request.terminalLink) {
            // Non-file links resolve without workspace roots, so this path opens no store.
            metadata = try SpacesDeviceTerminalLinkResolver.resolve(
                sessionID: sessionID, link: request.terminalLink, workingDirectory: nil, workspaceRoots: [])
        } else {
            let workspaceRoots = try loadWorkspaceRoots(store: context.store())
            metadata = try SpacesDeviceTerminalLinkResolver.resolve(
                sessionID: sessionID, link: request.terminalLink, workingDirectory: terminalWorkingDirectory(sessionID: sessionID),
                workspaceRoots: workspaceRoots)
        }
        if metadata.source == .localFile {
            let resolvedPath = try SpacesDeviceTerminalLinkResolver.resolvedLocalFilePath(linkID: metadata.id)
            authorizeTerminalLinkTransfer(linkID: metadata.id, sessionID: sessionID, resolvedPath: resolvedPath, now: Date())
        }
        return SpacesDeviceAPIResponse(ok: true, message: "Resolved terminal link.", result: .terminalLinkMetadata(metadata))
    }

    private func handleReadTerminalLinkChunkRequest(_ request: SpacesDeviceTerminalLinkChunkRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = request.sessionID
        let linkID = request.terminalLinkID
        guard let authorization = try terminalLinkTransferAuthorization(linkID: linkID, sessionID: sessionID, now: Date()) else {
            throw SpacesDeviceTerminalLinkResolverError.invalidLinkID
        }
        let chunk = try SpacesDeviceTerminalLinkResolver.readChunk(
            sessionID: sessionID, linkID: linkID, offset: request.offset, limit: request.limit, workspaceRoots: [authorization.resolvedPath])
        authorizeTerminalLinkTransfer(linkID: linkID, sessionID: sessionID, resolvedPath: authorization.resolvedPath, now: Date())
        return SpacesDeviceAPIResponse(ok: true, message: "Read terminal link chunk.", result: .terminalLinkChunk(chunk))
    }

    private func authorizeTerminalLinkTransfer(linkID: String, sessionID: String, resolvedPath: String, now: Date) {
        terminalLinkTransferAuthorizations[linkID] = TerminalLinkTransferAuthorization(
            sessionID: sessionID, resolvedPath: resolvedPath, expiresAt: now.addingTimeInterval(terminalLinkTransferAuthorizationTTL))
    }

    private func terminalLinkTransferAuthorization(linkID: String, sessionID: String, now: Date) throws -> TerminalLinkTransferAuthorization? {
        pruneTerminalLinkTransferAuthorizations(now: now)
        guard let authorization = terminalLinkTransferAuthorizations[linkID] else { return nil }
        guard authorization.sessionID == sessionID else { throw SpacesDeviceTerminalLinkResolverError.sessionMismatch }
        return authorization
    }

    private func pruneTerminalLinkTransferAuthorizations(now: Date) {
        terminalLinkTransferAuthorizations = terminalLinkTransferAuthorizations.filter { $0.value.expiresAt > now }
    }

    private func canResolveTerminalLinkWithoutLocalState(_ value: String?) -> Bool {
        guard let link = normalizedString(value), let scheme = URL(string: link)?.scheme?.lowercased() else { return false }
        return scheme != "file"
    }

    private func terminalWorkingDirectory(sessionID: String) throws -> String {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let workingDirectory = normalizedString((try? TerminalSessionPersistence.readRuntimeState(paths: paths))?.workingDirectory) {
            return workingDirectory
        }
        return try TerminalSessionPersistence.readLaunchConfiguration(paths: paths).workingDirectory
    }

    private func loadWorkspaceRoots(store: SQLiteStore) throws -> [String] {
        let projects = try store.projects()
        var roots = Set(projects.map(\.dir))
        for project in projects {
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: true)
            roots.formUnion(workspaces.map(\.dir))
        }
        return Array(roots)
    }

    #if os(Linux) && canImport(OpenSSL)
        private func prepareLinuxSubscribe(_ request: SpacesDeviceAPIRequest) throws -> LinuxSubscribeAction {
            if request.command.isDeviceOverviewSubscription {
                // Relay the device-overview producer socket (no terminal session,
                // no control heartbeat); the producer pushes the current overview
                // on connect and a fresh one on every database change.
                return .relay(
                    LinuxSubscription(
                        sessionID: "device-overview", installationID: request.clientApp?.installationID ?? "",
                        subscriptionSocketPath: try TerminalServicePaths.deviceOverviewSocketPath(), controlSocketPath: "", clientID: nil))
            }
            guard let sessionID = request.sessionID else { return .response(SpacesDeviceAPIResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument)) }
            guard let installationID = request.clientApp?.installationID.trimmingCharacters(in: .whitespacesAndNewlines), !installationID.isEmpty
            else { return .response(SpacesDeviceAPIResponse(ok: false, message: "Missing client installation ID.", errorCode: .invalidArgument)) }
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
                let payload =
                    (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))
                    ?? (try? endedStatePayload(sessionID: sessionID, paths: paths, runtimeState: runtimeState))
                if let payload { return .finalPayload(payload) }
                return .response(SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' has no final state.", errorCode: .sessionNotAvailable))
            }
            guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
                return .response(SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' has no live state stream.", errorCode: .sessionNotAvailable))
            }
            return .relay(
                LinuxSubscription(
                    sessionID: sessionID, installationID: installationID, subscriptionSocketPath: paths.subscriptionSocketPath,
                    controlSocketPath: paths.controlSocketPath, clientID: request.clientID))
        }

        private func relayLinuxSubscription(_ subscription: LinuxSubscription, ssl: OpaquePointer) throws {
            let relaySocketFD = try connectUnixSocket(path: subscription.subscriptionSocketPath)
            defer {
                Self.shutdownSocket(relaySocketFD, how: Self.shutdownReadWrite)
                close(relaySocketFD)
            }

            let heartbeatTimer: DispatchSourceTimer?
            if let clientID = subscription.clientID {
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                timer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
                timer.setEventHandler { [controlSocketPath = subscription.controlSocketPath] in
                    _ = try? TerminalControlClient.send(
                        request: TerminalControlRequest(command: .heartbeat(TerminalControlClientPayload(clientID: clientID))),
                        socketPath: controlSocketPath)
                }
                heartbeatTimer = timer
                timer.resume()
            } else {
                heartbeatTimer = nil
            }
            defer { heartbeatTimer?.cancel() }

            let startedAt = Date()
            let performanceLoggingEnabled = SpacesDeviceTerminalPerformanceLogger.isEnabled()
            var buffer = [UInt8](repeating: 0, count: Self.streamRelayReadBufferSize)
            while true {
                let count = read(relaySocketFD, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try buffer.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    let data = Data(bytes: baseAddress, count: count)
                    let attributes = performanceLoggingEnabled ? deviceAPIStreamRelayAttributes(for: data) : [:]
                    let writeStartedAt = performanceLoggingEnabled ? Date() : nil
                    if performanceLoggingEnabled {
                        logDeviceAPIPerformance(
                            sessionID: subscription.sessionID, name: "stream_relay_read",
                            emittedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds, count: count, attributes: attributes)
                        logDeviceAPIPerformance(
                            sessionID: subscription.sessionID, name: "stream_network_send_begin", count: count, attributes: attributes)
                    }
                    try LinuxServer.writeTLSResponse(data, ssl: ssl)
                    if let writeStartedAt {
                        logDeviceAPIPerformance(
                            sessionID: subscription.sessionID, name: "stream_network_send_end",
                            elapsedMS: TerminalPerformance.elapsedMS(since: writeStartedAt), count: count, attributes: attributes)
                    }
                }
            }
            TerminalPerformance.logMetric(
                "device_api_subscribe", target: "session=\(subscription.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                success: true)
        }

    #endif

    #if canImport(Network) && canImport(Security)
        private func handleSubscribeRequest(_ request: SpacesDeviceAPIRequest, connection: NWConnection) throws {
            if request.command.isDeviceOverviewSubscription {
                try relayOverviewSubscription(connection: connection, installationID: request.clientApp?.installationID ?? "")
                return
            }
            guard let sessionID = request.sessionID else {
                sendResponse(SpacesDeviceAPIResponse(ok: false, message: "Missing session ID.", errorCode: .invalidArgument), to: connection) { _ in connection.cancel() }
                return
            }
            guard let installationID = request.clientApp?.installationID.trimmingCharacters(in: .whitespacesAndNewlines), !installationID.isEmpty
            else {
                sendResponse(SpacesDeviceAPIResponse(ok: false, message: "Missing client installation ID.", errorCode: .invalidArgument), to: connection) { _ in
                    connection.cancel()
                }
                return
            }
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
                let payload =
                    (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))
                    ?? (try? endedStatePayload(sessionID: sessionID, paths: paths, runtimeState: runtimeState))
                if let payload {
                    sendStreamPayloadAndComplete(payload, sessionID: sessionID, to: connection)
                } else {
                    sendResponse(SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' has no final state.", errorCode: .sessionNotAvailable), to: connection) {
                        _ in connection.cancel()
                    }
                }
                return
            }
            guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
                sendResponse(SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' has no live state stream.", errorCode: .sessionNotAvailable), to: connection)
                { _ in connection.cancel() }
                return
            }

            let startedAt = Date()
            let relaySocketFD = try connectUnixSocket(path: paths.subscriptionSocketPath)
            try setNonBlocking(relaySocketFD)

            let relayQueue = DispatchQueue(label: "spaces.device.api.stream.\(sessionID).\(ObjectIdentifier(connection))")
            let relaySource = DispatchSource.makeReadSource(fileDescriptor: relaySocketFD, queue: relayQueue)
            relaySource.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.relayStateData(from: relaySocketFD, to: connection)
            }
            relaySource.setCancelHandler { close(relaySocketFD) }

            let heartbeatTimer: DispatchSourceTimer?
            if let clientID = request.clientID {
                let timer = DispatchSource.makeTimerSource(queue: relayQueue)
                timer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
                timer.setEventHandler {
                    _ = try? TerminalControlClient.send(
                        request: TerminalControlRequest(command: .heartbeat(TerminalControlClientPayload(clientID: clientID))),
                        socketPath: paths.controlSocketPath)
                }
                heartbeatTimer = timer
            } else {
                heartbeatTimer = nil
            }

            streamRelays[ObjectIdentifier(connection)] = StreamRelay(
                sessionID: sessionID, installationID: installationID, relaySocketFD: relaySocketFD, relayQueue: relayQueue, relaySource: relaySource,
                heartbeatTimer: heartbeatTimer, connection: connection, sendSequencer: StreamSendSequencer(queueKey: queueKey))

            relaySource.resume()
            heartbeatTimer?.resume()

            TerminalPerformance.logMetric(
                "device_api_subscribe", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
        }

        /// Relays the device-overview producer socket to a subscribing connection,
        /// reusing the same stream-relay machinery as terminal subscriptions (no
        /// terminal heartbeat). The producer sends the current overview on connect
        /// and a fresh one on every database change.
        private func relayOverviewSubscription(connection: NWConnection, installationID: String) throws {
            let socketPath = try TerminalServicePaths.deviceOverviewSocketPath()
            let relaySocketFD = try connectUnixSocket(path: socketPath)
            try setNonBlocking(relaySocketFD)
            let relayQueue = DispatchQueue(label: "spaces.device.api.overview.\(ObjectIdentifier(connection))")
            let relaySource = DispatchSource.makeReadSource(fileDescriptor: relaySocketFD, queue: relayQueue)
            relaySource.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.relayStateData(from: relaySocketFD, to: connection)
            }
            relaySource.setCancelHandler { close(relaySocketFD) }
            streamRelays[ObjectIdentifier(connection)] = StreamRelay(
                sessionID: "device-overview", installationID: installationID, relaySocketFD: relaySocketFD, relayQueue: relayQueue,
                relaySource: relaySource, heartbeatTimer: nil, connection: connection, sendSequencer: StreamSendSequencer(queueKey: queueKey))
            relaySource.resume()
        }

    #endif

    #if canImport(Network) && canImport(Security)
        private func sendStreamPayloadAndComplete(_ payload: GhosttyRemoteSessionStatePayload, sessionID: String, to connection: NWConnection) {
            do {
                let data = try GhosttyRemoteSessionStateCodec.encodeLine(payload)
                let attributes = deviceAPIStreamRelayAttributes(for: data)
                logDeviceAPIPerformance(sessionID: sessionID, name: "stream_relay_read", count: data.count, attributes: attributes)
                networkShaper.send(
                    content: data, to: connection, on: queue,
                    onSendBegin: { [weak self, sessionID, attributes, count = data.count] in
                        self?.logDeviceAPIPerformance(sessionID: sessionID, name: "stream_network_send_begin", count: count, attributes: attributes)
                    }, isComplete: true
                ) { [weak self, weak connection] error in
                    if let error {
                        self?.trace("stream_final_payload_send_error session=\(sessionID) error=\(error)")
                        connection?.cancel()
                    } else {
                        connection?.cancel()
                    }
                }
            } catch {
                sendResponse(
                    SpacesDeviceAPIResponse(ok: false, message: String(describing: error), errorCode: SpacesDeviceAPIServer.errorCode(for: error)),
                    to: connection
                ) { _ in connection.cancel() }
            }
        }

        private func relayStateData(from relaySocketFD: Int32, to connection: NWConnection) {
            var buffer = [UInt8](repeating: 0, count: Self.streamRelayReadBufferSize)
            var relayedData = Data()
            var firstReadUptimeNanoseconds: UInt64?
            while true {
                let count = read(relaySocketFD, &buffer, buffer.count)
                if count == 0 {
                    if !relayedData.isEmpty {
                        enqueueRelayedStateData(
                            relayedData, firstReadUptimeNanoseconds: firstReadUptimeNanoseconds, to: connection, closeAfterSend: true)
                    } else {
                        queue.async { [weak self, weak connection] in
                            guard let self, let connection else { return }
                            self.closeStreamRelayAfterQueuedSendsDrain(connection: connection)
                        }
                    }
                    return
                }
                if count < 0 {
                    if errno == EWOULDBLOCK || errno == EAGAIN {
                        if !relayedData.isEmpty {
                            enqueueRelayedStateData(relayedData, firstReadUptimeNanoseconds: firstReadUptimeNanoseconds, to: connection)
                        }
                        return
                    }
                    queue.async { [weak self, weak connection] in
                        guard let self, let connection else { return }
                        self.closeStreamRelayUnlessFinalSendPending(connection: connection)
                    }
                    return
                }
                firstReadUptimeNanoseconds = firstReadUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds
                relayedData.append(buffer, count: count)
            }
        }

        private func enqueueRelayedStateData(
            _ data: Data, firstReadUptimeNanoseconds: UInt64?, to connection: NWConnection, closeAfterSend: Bool = false
        ) {
            queue.async { [weak self, weak connection, data, firstReadUptimeNanoseconds, closeAfterSend] in
                guard let self, let connection else { return }
                if closeAfterSend, self.prepareStreamRelayForFinalSend(connection: connection) == nil { return }
                self.sendRelayedStateData(
                    data, firstReadUptimeNanoseconds: firstReadUptimeNanoseconds, to: connection, closeAfterSend: closeAfterSend)
            }
        }

        private func prepareStreamRelayForFinalSend(connection: NWConnection) -> (relay: StreamRelay, didStartClosing: Bool)? {
            let key = ObjectIdentifier(connection)
            guard let relay = streamRelays[key] else { return nil }
            let didStartClosing = streamRelaysClosingAfterFinalSend.insert(key).inserted
            guard didStartClosing else { return (relay, false) }
            relay.heartbeatTimer?.cancel()
            relay.relaySource.cancel()
            shutdown(relay.relaySocketFD, SHUT_RDWR)
            return (relay, true)
        }

        private func sendRelayedStateData(
            _ data: Data, firstReadUptimeNanoseconds: UInt64?, to connection: NWConnection, closeAfterSend: Bool = false
        ) {
            guard let relay = streamRelays[ObjectIdentifier(connection)] else { return }
            let performanceLoggingEnabled = SpacesDeviceTerminalPerformanceLogger.isEnabled()
            let attributes = performanceLoggingEnabled ? deviceAPIStreamRelayAttributes(for: data) : [:]
            if performanceLoggingEnabled {
                logDeviceAPIPerformance(
                    sessionID: relay.sessionID, name: "stream_relay_read",
                    emittedUptimeNanoseconds: firstReadUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds, count: data.count,
                    attributes: attributes)
            }
            relay.sendSequencer.enqueue {
                [weak self, weak connection, sessionID = relay.sessionID, attributes, data, closeAfterSend, performanceLoggingEnabled] finish in
                guard let self, let connection else {
                    finish(nil)
                    return
                }
                self.networkShaper.send(
                    content: data, to: connection, on: self.queue,
                    onSendBegin: { [weak self, sessionID, attributes, count = data.count] in
                        guard performanceLoggingEnabled else { return }
                        var sendAttributes = attributes
                        sendAttributes["network_send_bytes"] = String(count)
                        self?.logDeviceAPIPerformance(
                            sessionID: sessionID, name: "stream_network_send_begin", count: count, attributes: sendAttributes)
                    }, isComplete: closeAfterSend, applyInitialDelay: closeAfterSend, applyBandwidthDelay: closeAfterSend
                ) { [weak self, weak connection] error in
                    self?.queue.async { [weak self, weak connection] in
                        if let error {
                            self?.trace("stream_relay_send_error error=\(error)")
                            if let self, let connection { self.closeStreamRelay(connection: connection) }
                        } else if closeAfterSend, let self, let connection {
                            self.closeStreamRelay(connection: connection)
                        }
                        finish(error)
                    }
                }
            }
        }

        private func closeStreamRelay(connection: NWConnection, cancelNetworkConnection: Bool = true) {
            let key = ObjectIdentifier(connection)
            guard let relay = streamRelays.removeValue(forKey: key) else {
                streamRelaysClosingAfterFinalSend.remove(key)
                return
            }
            let relayReadSideAlreadyClosed = streamRelaysClosingAfterFinalSend.remove(key) != nil
            trace("stream_relay_close peer=\(String(describing: connection.endpoint))")
            if !relayReadSideAlreadyClosed {
                relay.heartbeatTimer?.cancel()
                relay.relaySource.cancel()
                shutdown(relay.relaySocketFD, SHUT_RDWR)
            }
            if cancelNetworkConnection { connection.cancel() }
        }

        private func closeStreamRelayUnlessFinalSendPending(connection: NWConnection) {
            guard !streamRelaysClosingAfterFinalSend.contains(ObjectIdentifier(connection)) else { return }
            closeStreamRelay(connection: connection)
        }

        private func closeStreamRelayAfterQueuedSendsDrain(connection: NWConnection) {
            guard let prepared = prepareStreamRelayForFinalSend(connection: connection), prepared.didStartClosing else { return }
            prepared.relay.sendSequencer.enqueue { [weak self, weak connection] finish in
                defer { finish(nil) }
                guard let self, let connection else { return }
                self.closeStreamRelay(connection: connection)
            }
        }

        private func closeRequestConnection(connection: NWConnection) {
            requestConnections.removeValue(forKey: ObjectIdentifier(connection))
            trace("request_connection_closed active=\(requestConnections.count)")
        }

        private func closeRequestConnectionAfterNetworkUpdate(connection: NWConnection, cancelNetworkConnection: Bool) {
            performOnQueue {
                self.closeStreamRelay(connection: connection, cancelNetworkConnection: cancelNetworkConnection)
                self.closeRequestConnection(connection: connection)
            }
        }

        private func closeStreamRelaysOnQueue(forInstallationID installationID: String) {
            let normalizedID = installationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else { return }
            let connections = streamRelays.values.filter { $0.installationID == normalizedID }.map(\.connection)
            for connection in connections { closeStreamRelay(connection: connection) }
        }
    #elseif os(Linux) && canImport(OpenSSL)
        private func closeStreamRelaysOnQueue(forInstallationID installationID: String) {
            let normalizedID = installationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else { return }
            linuxServer?.closeConnections(forInstallationID: normalizedID)
        }
    #endif

    private func stopOnQueue() {
        acceptingRequests = false
        stopOverviewStreamServer()
        #if canImport(Network) && canImport(Security)
            for relay in Array(streamRelays.values) { closeStreamRelay(connection: relay.connection) }
            for connection in Array(requestConnections.values.map(\.connection)) { connection.cancel() }
            requestConnections.removeAll()
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
        #elseif os(Linux) && canImport(OpenSSL)
            linuxServer?.stop()
            linuxServer = nil
        #endif
        terminalLinkTransferAuthorizations.removeAll()
        setRunning(false)
    }

    private func syncOnQueue<T>(_ work: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try work() }
        return try queue.sync(execute: work)
    }

    private func performOnQueue(_ work: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { work() } else { queue.async(execute: work) }
    }

    private func connectUnixSocket(path: String) throws -> Int32 {
        let socketFD = socket(AF_UNIX, Self.streamSocketType, 0)
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
            utf8Path.withUnsafeBufferPointer { buffer in if let baseAddress = buffer.baseAddress { memcpy(pointer, baseAddress, buffer.count) } }
        }
        return address
    }

    private func loadCurrentState(sessionID: String) throws -> GhosttyRemoteSessionStatePayload {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            if let finalState = try? TerminalSessionPersistence.readRemoteSessionState(paths: paths) { return finalState }
            return try endedStatePayload(sessionID: sessionID, paths: paths, runtimeState: runtimeState)
        }
        guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
            throw NSError(
                domain: "SpacesDeviceAPIServer", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' has no live state stream."])
        }

        let socketFD = try connectUnixSocket(path: paths.subscriptionSocketPath)
        defer {
            Self.shutdownSocket(socketFD, how: Self.shutdownReadWrite)
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
                domain: "SpacesDeviceAPIServer", code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Terminal session '\(sessionID)' did not return a state payload."])
        }
        return try GhosttyRemoteSessionStateCodec.decodeLine(data)
    }

    private func endedStatePayload(sessionID: String, paths: TerminalSessionPaths, runtimeState: TerminalSessionRuntimeState) throws
        -> GhosttyRemoteSessionStatePayload
    {
        let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        let attachmentSnapshot = (try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? TerminalSessionAttachmentSnapshot()
        let emittedAt = runtimeState.exitedAt ?? runtimeState.updatedAt
        return GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: emittedAt, sessionStateRevision: nil,
            sessionStateFlags: nil, screenStateRevision: nil, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
            title: runtimeState.title ?? launchConfiguration?.title ?? sessionID,
            workingDirectory: runtimeState.workingDirectory ?? launchConfiguration?.workingDirectory ?? paths.rootDirectory, outputByteCount: nil)
    }

    #if canImport(Network) && canImport(Security)
        private func sendResponse(_ response: SpacesDeviceAPIResponse, to connection: NWConnection, completion: @escaping @Sendable (Error?) -> Void)
        {
            do {
                var data = try SpacesDeviceAPICodec.encodeResponse(response)
                data.append(0x0A)
                networkShaper.send(content: data, to: connection, on: queue, completion: completion)
            } catch { completion(error) }
        }
    #endif

    private func setNonBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func setNoSIGPIPE(_ fileDescriptor: Int32) throws {
        #if canImport(Darwin)
            var yes: Int32 = 1
            guard setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        #endif
    }

    #if canImport(Network) && canImport(Security)
        private static func nwPort(_ port: Int) throws -> NWEndpoint.Port {
            guard (0...65_535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw POSIXError(.EINVAL) }
            return nwPort
        }
    #endif

    private static func shutdownSocket(_ fileDescriptor: Int32, how: Int32) {
        #if canImport(Glibc)
            shutdown(fileDescriptor, how)
        #else
            shutdown(fileDescriptor, how)
        #endif
    }

    private static var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }

    private static var shutdownReadWrite: Int32 {
        #if canImport(Glibc)
            Int32(SHUT_RDWR)
        #else
            SHUT_RDWR
        #endif
    }

    private func trace(_ message: String) {
        guard traceEnabled else { return }
        FileHandle.standardOutput.write(Data("spaces-device-api-trace \(message)\n".utf8))
    }

    private func logDeviceAPIPerformance(
        sessionID: String, name: String, emittedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds, elapsedMS: Int? = nil,
        count: Int? = nil, attributes: [String: String] = [:]
    ) {
        SpacesDeviceTerminalPerformanceLogger.emit(
            .init(
                sessionID: sessionID, source: "device-api", name: name, emittedUptimeNanoseconds: emittedUptimeNanoseconds, elapsedMS: elapsedMS,
                count: count, attributes: attributes))
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        running = value
        stateLock.unlock()
    }
}
