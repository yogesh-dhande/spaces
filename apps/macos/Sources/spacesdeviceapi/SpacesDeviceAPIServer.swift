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
    func issueToken(for clientApp: SpacesDeviceClientApp) throws -> String
    func listDevices() throws -> [SpacesDevicePairedClient]
    func revoke(installationID: String) throws
    func removeAll() throws
    func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws
    func validate(clientApp: SpacesDeviceClientApp) throws
}

extension SpacesDevicePairingStore: SpacesDevicePairingStoreProtocol {}

public final class SpacesDeviceAPIServer: @unchecked Sendable {
    private static let ownerGatedTerminalCommands: Set<SpacesDeviceTerminalControlAction> = [.send, .key, .clearScreen, .resize, .scroll]
    private static let streamRelayReadBufferSize = 256 * 1024
    private static let defaultTerminalLinkTransferAuthorizationTTL: TimeInterval = 10 * 60

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

            private var pendingOperations: [Operation] = []
            private var isRunning = false

            func enqueue(_ operation: @escaping Operation) {
                pendingOperations.append(operation)
                startNextIfNeeded()
            }

            private func startNextIfNeeded() {
                guard !isRunning, !pendingOperations.isEmpty else { return }
                isRunning = true
                let operation = pendingOperations.removeFirst()
                operation { [weak self] _ in self?.finishCurrent() }
            }

            private func finishCurrent() {
                isRunning = false
                startNextIfNeeded()
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
                    server.sendResponse(SpacesDeviceAPIResponse(ok: false, message: message), to: connection) { [weak self] _ in
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

    private final class StartupSignal: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var result: Result<Void, Error>?

        func signal(_ result: Result<Void, Error>) {
            lock.lock()
            let shouldSignal = self.result == nil
            if shouldSignal { self.result = result }
            lock.unlock()
            if shouldSignal { semaphore.signal() }
        }

        func wait(timeout: TimeInterval) -> Result<Void, Error> {
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return .failure(POSIXError(.ETIMEDOUT)) }
            lock.lock()
            let result = self.result ?? .failure(POSIXError(.EIO))
            lock.unlock()
            return result
        }
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
            private let transportKey: String
            private let server: SpacesDeviceAPIServer
            private let queue: DispatchQueue
            private var listenSocketFD: Int32 = -1
            private var acceptSource: DispatchSourceRead?
            private var sslContext: OpaquePointer?
            private let activeConnectionLock = NSLock()
            private var activeConnectionsByFD: [Int32: String] = [:]

            private(set) var listeningPort: Int = 0

            init(host: String, port: Int, transportKey: String, server: SpacesDeviceAPIServer, queue: DispatchQueue) {
                self.host = host
                self.port = port
                self.transportKey = transportKey
                self.server = server
                self.queue = queue
            }

            func start(timeout: TimeInterval = 5) throws {
                guard (0...Int(UInt16.max)).contains(port) else { throw POSIXError(.EINVAL) }
                let context = try Self.makeSSLContext(transportKey: transportKey)
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
                    let request: SpacesDeviceAPIRequest
                    do { request = try SpacesDeviceAPICodec.decodeRequest(requestData) } catch {
                        try Self.writeTLSResponse(
                            try SpacesDeviceAPICodec.encodeResponseLine(.init(ok: false, message: String(describing: error))), ssl: ssl)
                        return
                    }

                    if request.command.isSubscriptionCommand {
                        let action = try server.syncOnQueue {
                            try server.authorize(request)
                            return try server.prepareLinuxSubscribe(request)
                        }
                        switch action {
                        case .response(let response): try Self.writeTLSResponse(try SpacesDeviceAPICodec.encodeResponseLine(response), ssl: ssl)
                        case .finalPayload(let payload): try Self.writeTLSResponse(try GhosttyRemoteSessionStateCodec.encodeLine(payload), ssl: ssl)
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
                        response = SpacesDeviceAPIResponse(ok: false, message: message)
                    }
                    try Self.writeTLSResponse(try SpacesDeviceAPICodec.encodeResponseLine(response), ssl: ssl)
                    if !response.ok, response.message.localizedStandardContains("unauthorized") { return }
                }
            }

            private static func makeSSLContext(transportKey: String) throws -> OpaquePointer {
                OPENSSL_init_ssl(0, nil)
                guard let method = TLS_server_method(), let context = SSL_CTX_new(method) else { throw POSIXError(.EIO) }
                guard spaces_SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) == 1 else {
                    SSL_CTX_free(context)
                    throw POSIXError(.EIO)
                }
                _ = spaces_SSL_CTX_set_max_proto_version(context, TLS1_2_VERSION)
                let keyData = try SpacesDeviceAPITransport.decodeTransportKey(transportKey)
                let configured = keyData.withUnsafeBytes { keyBuffer -> Int32 in
                    guard let keyAddress = keyBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return SpacesDeviceAPITransport.pskIdentity.withCString { identity in
                        spaces_SSL_CTX_configure_device_api_psk(context, keyAddress, UInt32(keyBuffer.count), identity)
                    }
                }
                guard configured == 1 else {
                    SSL_CTX_free(context)
                    throw POSIXError(.EACCES)
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
    private let transportKey: String
    private let certificateFingerprint: String
    private let pairingCoordinator: SpacesDevicePairingCoordinator
    private let pairingStore: any SpacesDevicePairingStoreProtocol
    private let onPairingSucceeded: (@Sendable (SpacesDeviceClientApp) -> Void)?
    private let launchSpacesAppHandler: (() throws -> SpacesAppLaunchOutcome)?
    private let builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator?
    private let builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher?
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private let terminalLinkTransferAuthorizationTTL: TimeInterval
    private let traceEnabled = ProcessInfo.processInfo.environment["SPACES_DEVICE_API_TRACE"] == "1"

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
        host: String, port: Int, transportKey: String, certificateFingerprint: String = SpacesDeviceAPISettings.generateCertificateFingerprint(),
        pairingCoordinator: SpacesDevicePairingCoordinator = SpacesDevicePairingCoordinator(), pairingStore: SpacesDevicePairingStore? = nil,
        onPairingSucceeded: (@Sendable (SpacesDeviceClientApp) -> Void)? = nil,
        builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator? = nil,
        builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil
    ) throws {
        self.host = host
        self.port = port
        self.transportKey = transportKey
        self.certificateFingerprint = certificateFingerprint
        self.pairingCoordinator = pairingCoordinator
        self.onPairingSucceeded = onPairingSucceeded
        launchSpacesAppHandler = nil
        self.builtInTerminalSessionTerminator = builtInTerminalSessionTerminator
        self.builtInTerminalSessionLauncher = builtInTerminalSessionLauncher
        if let pairingStore { self.pairingStore = pairingStore } else { self.pairingStore = try SpacesDevicePairingStore() }
        #if canImport(Network) && canImport(Security)
            networkShaper = NetworkShaper()
        #endif
        terminalLinkTransferAuthorizationTTL = Self.defaultTerminalLinkTransferAuthorizationTTL
        queue = DispatchQueue(label: "spaces.device.api")
        queue.setSpecific(key: queueKey, value: ())
    }

    init(
        host: String, port: Int, transportKey: String, certificateFingerprint: String = SpacesDeviceAPISettings.generateCertificateFingerprint(),
        pairingCoordinator: SpacesDevicePairingCoordinator = SpacesDevicePairingCoordinator(),
        pairingStoreProtocol: any SpacesDevicePairingStoreProtocol, onPairingSucceeded: (@Sendable (SpacesDeviceClientApp) -> Void)? = nil,
        networkEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        launchSpacesAppHandler: (() throws -> SpacesAppLaunchOutcome)? = nil,
        builtInTerminalSessionTerminator: WorkspaceOrchestrator.BuiltInTerminalSessionTerminator? = nil,
        builtInTerminalSessionLauncher: WorkspaceOrchestrator.BuiltInTerminalSessionLauncher? = nil,
        terminalLinkTransferAuthorizationTTL: TimeInterval = SpacesDeviceAPIServer.defaultTerminalLinkTransferAuthorizationTTL
    ) {
        self.host = host
        self.port = port
        self.transportKey = transportKey
        self.certificateFingerprint = certificateFingerprint
        self.pairingCoordinator = pairingCoordinator
        self.pairingStore = pairingStoreProtocol
        self.onPairingSucceeded = onPairingSucceeded
        self.launchSpacesAppHandler = launchSpacesAppHandler
        self.builtInTerminalSessionTerminator = builtInTerminalSessionTerminator
        self.builtInTerminalSessionLauncher = builtInTerminalSessionLauncher
        #if canImport(Network) && canImport(Security)
            networkShaper = NetworkShaper(environment: networkEnvironment)
        #endif
        self.terminalLinkTransferAuthorizationTTL = terminalLinkTransferAuthorizationTTL
        queue = DispatchQueue(label: "spaces.device.api")
        queue.setSpecific(key: queueKey, value: ())
    }

    public private(set) var listeningPort: Int = 0

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
            let parameters = try SpacesDeviceAPITransport.parameters(transportKey: transportKey, role: .server)
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

            switch startup.wait(timeout: timeout) {
            case .success: break
            case .failure(let error):
                createdListener.stateUpdateHandler = nil
                createdListener.newConnectionHandler = nil
                createdListener.cancel()
                throw error
            }
        #elseif os(Linux) && canImport(OpenSSL)
            let createdServer = LinuxServer(host: host, port: port, transportKey: transportKey, server: self, queue: queue)
            try createdServer.start(timeout: timeout)
            linuxServer = createdServer
            listeningPort = createdServer.listeningPort
            acceptingRequests = true
            setRunning(true)
        #else
            throw POSIXError(.ENOTSUP)
        #endif
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
            host: linkHost, port: listeningPort > 0 ? listeningPort : port, transportKey: transportKey,
            certificateFingerprint: certificateFingerprint, name: name, duration: duration)
    }

    public func openPairingWindow(
        host linkHost: String, name: String, duration: TimeInterval = SpacesDevicePairingCoordinator.defaultWindowDuration, code: String,
        nonce: String? = nil
    ) -> SpacesDevicePairingWindow {
        pairingCoordinator.openWindow(
            host: linkHost, port: listeningPort > 0 ? listeningPort : port, transportKey: transportKey,
            certificateFingerprint: certificateFingerprint, name: name, duration: duration, code: code, nonce: nonce)
    }

    public func pairingWindowSnapshot() -> SpacesDevicePairingWindowSnapshot? { pairingCoordinator.snapshot() }

    private func handleRequest(_ request: SpacesDeviceAPIRequest, peerID: String) throws -> SpacesDeviceAPIResponse {
        switch request.command {
        case .pair(let payload):
            guard let clientApp = request.clientApp else {
                return SpacesDeviceAPIResponse(ok: false, message: SpacesDevicePairingError.missingClientApp.localizedDescription)
            }
            try pairingStore.validate(clientApp: clientApp)
            try pairingCoordinator.validate(code: payload.pairingCode, nonce: payload.pairingNonce, peerID: peerID)
            let issuedToken = try pairingStore.issueToken(for: clientApp)
            onPairingSucceeded?(clientApp)
            return SpacesDeviceAPIResponse(ok: true, message: "Paired iOS client.", result: .issuedAuthToken(.init(authToken: issuedToken)))
        case .ping: return SpacesDeviceAPIResponse(ok: true, message: "pong")
        case .overview:
            return SpacesDeviceAPIResponse(
                ok: true, message: "Loaded device overview.", result: .overview(try loadOverview(clientApp: request.clientApp)))
        case .launchSpacesApp: return try handleLaunchSpacesAppRequest()
        case .createProject(let payload): return try handleCreateProjectRequest(payload)
        case .deleteProject(let payload): return try handleDeleteProjectRequest(payload)
        case .importProject(let payload): return try handleImportProjectRequest(payload)
        case .exportProject(let payload): return try handleExportProjectRequest(payload)
        case .workspaceCreateOptions(let payload): return try handleWorkspaceCreateOptionsRequest(payload)
        case .createWorkspace(let payload): return try handleCreateWorkspaceRequest(payload)
        case .launchWorkspace(let payload): return try handleLaunchWorkspaceRequest(payload)
        case .stopWorkspace(let payload): return try handleStopWorkspaceRequest(payload)
        case .restartWorkspace(let payload): return try handleRestartWorkspaceRequest(payload)
        case .archiveWorkspace(let payload): return try handleArchiveWorkspaceRequest(payload)
        case .runWorkspaceSetup(let payload): return try handleRunWorkspaceSetupRequest(payload)
        case .updateProjectConfig(let payload): return try handleUpdateProjectConfigRequest(payload)
        case .updateWorkspaceConfig(let payload): return try handleUpdateWorkspaceConfigRequest(payload)
        case .updateWorkspaceMetadata(let payload): return try handleUpdateWorkspaceMetadataRequest(payload)
        case .openWorkspaceTerminal(let payload): return try handleOpenWorkspaceTerminalRequest(payload)
        case .stopWorkspaceTerminal(let payload): return try handleStopWorkspaceTerminalRequest(payload)
        case .runWorkspaceProcess(let payload): return try handleRunWorkspaceProcessRequest(payload)
        case .stopWorkspaceProcess(let payload): return try handleStopWorkspaceProcessRequest(payload)
        case .restartWorkspaceProcess(let payload): return try handleRestartWorkspaceProcessRequest(payload)
        case .runCodingAgent(let payload): return try handleRunCodingAgentRequest(payload)
        case .stopCodingAgent(let payload): return try handleStopCodingAgentRequest(payload)
        case .restartCodingAgent(let payload): return try handleRestartCodingAgentRequest(payload)
        case .state(let payload): return try handleStateRequest(payload)
        case .terminalControl(let payload): return try handleTerminalControlRequest(payload)
        case .resolveTerminalLink(let payload): return try handleResolveTerminalLinkRequest(payload)
        case .readTerminalLinkChunk(let payload): return try handleReadTerminalLinkChunkRequest(payload)
        case .subscribe: return SpacesDeviceAPIResponse(ok: false, message: "Subscription requests must use the stream path.")
        }
    }

    private func authorize(_ request: SpacesDeviceAPIRequest) throws {
        guard !request.command.isPairingCommand else { return }
        do { try pairingStore.authorize(clientApp: request.clientApp, authToken: request.authToken) } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw NSError(domain: "SpacesDeviceAPIServer", code: 401, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func handleTerminalControlRequest(_ payload: SpacesDeviceTerminalControlRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = payload.sessionID
        let clientID = Self.normalizedClientID(payload.clientID)
        trace(
            "terminal_control_request source_session=\(sessionID) target_session=\(sessionID) client=\(clientID ?? payload.client?.id ?? "-") command=\(payload.action.rawValue)"
        )
        if Self.ownerGatedTerminalCommands.contains(payload.action), clientID == nil {
            return SpacesDeviceAPIResponse(ok: false, message: "Missing device client ID.")
        }

        let startedAt = Date()
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not running.")
        }
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' is not available.")
        }

        let terminalRequest = TerminalControlRequest(
            command: payload.action.rawValue, text: payload.text, key: payload.key, clientID: clientID, client: payload.client,
            attachmentMode: payload.attachmentMode, columns: payload.columns, rows: payload.rows, ownerEpoch: payload.ownerEpoch,
            resizeSerial: payload.resizeSerial, scrollHorizontal: payload.scrollHorizontal, scrollVertical: payload.scrollVertical,
            scrollMods: payload.scrollMods, appendNewline: payload.appendNewline)
        let response = try TerminalControlClient.send(request: terminalRequest, socketPath: paths.controlSocketPath)
        TerminalPerformance.logMetric(
            "device_api_\(payload.action.rawValue)", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: response.ok)
        let sessionState = response.ok && payload.action == .takeover ? try? loadCurrentState(sessionID: sessionID) : nil
        return SpacesDeviceAPIResponse(ok: response.ok, message: response.message, result: sessionState.map(SpacesDeviceAPIResult.terminalState))
    }

    private static func normalizedClientID(_ value: String?) -> String? {
        guard let clientID = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clientID.isEmpty else { return nil }
        return clientID
    }

    private func handleLaunchSpacesAppRequest() throws -> SpacesDeviceAPIResponse {
        guard let launchSpacesAppHandler else {
            return SpacesDeviceAPIResponse(ok: false, message: "launchSpacesApp is only available from the daemon-hosted Device API.")
        }
        let outcome = try launchSpacesAppHandler()
        return SpacesDeviceAPIResponse(ok: true, message: outcome.message)
    }

    private func loadOverview(clientApp: SpacesDeviceClientApp? = nil) throws -> SpacesDeviceOverviewPayload {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let orchestrator = deviceOrchestrator(store: store)
        let projects = try store.projects()
        let workspaces = try projects.flatMap { project in
            try store.workspaces(projectID: project.id, includeArchived: false).map { workspace in
                SpacesDeviceOverviewBuilder.WorkspaceDescriptor(
                    project: project, workspace: workspace, settings: try? orchestrator.workspaceSettings(workspaceID: workspace.id),
                    runningProcesses: try store.runningProcesses(workspaceID: workspace.id),
                    agentWindows: try store.agentWindows(workspaceID: workspace.id), windows: try store.windows(workspaceID: workspace.id),
                    assignedPorts: (try? orchestrator.workspacePortsNamed(workspaceID: workspace.id).map {
                        SpacesDeviceAssignedPort(name: $0.name, port: $0.port)
                    }) ?? [], resolvedBrowserSessions: (try? orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)) ?? [],
                    setupState: try? orchestrator.workspaceSetupState(workspaceID: workspace.id), terminalDaemonEndpoint: nil)
            }
        }
        let localSessions = try TerminalSessionCatalog.listLiveSessions()
        let sessions = mergedTerminalSessions(localSessions)
        let workspaceRows = try loadWorkspaceTerminalRows(store: store, workspaces: workspaces, sessions: sessions, hasFinalRenderBySessionID: [:])
        return SpacesDeviceOverviewBuilder.build(projects: projects, workspaces: workspaces, workspaceRows: workspaceRows, liveSessions: sessions)
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

    private func loadWorkspaceTerminalRows(
        store: SQLiteStore, workspaces: [SpacesDeviceOverviewBuilder.WorkspaceDescriptor], sessions: [TerminalSessionCatalogEntry],
        hasFinalRenderBySessionID: [String: Bool]
    ) throws -> [SpacesDeviceOverviewBuilder.WorkspaceTerminalRow] {
        var rows: [SpacesDeviceOverviewBuilder.WorkspaceTerminalRow] = []
        var representedSessionIDs = Set<String>()
        let sessionsByID = Dictionary(sessions.map { ($0.sessionID, $0) }, uniquingKeysWith: { existing, _ in existing })
        for descriptor in workspaces {
            let processesBySlot = Dictionary(grouping: try store.runningProcesses(workspaceID: descriptor.workspace.id), by: { processSlotKey($0) })
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

            let agentsBySlot = Dictionary(grouping: try store.agentWindows(workspaceID: descriptor.workspace.id), by: { agentSlotKey($0) })
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

    private func handleWorkspaceCreateOptionsRequest(_ request: SpacesDeviceWorkspaceCreateOptionsRequest) throws -> SpacesDeviceAPIResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let orchestrator = deviceOrchestrator(store: store)
        let projects = try store.projects().map {
            SpacesDeviceProjectSummary(
                id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch, isCollapsed: $0.isCollapsed)
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

    private func handleCreateProjectRequest(_ request: SpacesDeviceProjectCreateRequest) throws -> SpacesDeviceAPIResponse {
        let projectDir = normalizedString(request.projectDir)
        let gitURL = normalizedString(request.gitURL)
        guard (projectDir == nil) != (gitURL == nil) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Provide exactly one project directory or Git URL.")
        }

        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let orchestrator = deviceOrchestrator(store: store)
        let project: ProjectRecord
        if let projectDir {
            if let config = request.config {
                project = try orchestrator.addReviewedProject(dir: projectDir) { project in applyProjectConfig(config, to: &project) }
            } else {
                project = try orchestrator.addProject(dir: projectDir)
            }
        } else if let gitURL {
            project = try orchestrator.addProject(gitURL: gitURL) { project in
                if let config = request.config { applyProjectConfig(config, to: &project) }
            }
        } else {
            return SpacesDeviceAPIResponse(ok: false, message: "Provide exactly one project directory or Git URL.")
        }
        let defaultWorkspaceID = try store.workspaces(projectID: project.id, includeArchived: false).first(where: \.isDefault)?.id
        return try refreshedMutationResponse(message: "Created project '\(project.name)'.", projectID: project.id, workspaceID: defaultWorkspaceID)
    }

    private func handleDeleteProjectRequest(_ request: SpacesDeviceProjectReference) throws -> SpacesDeviceAPIResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let orchestrator = deviceOrchestrator(store: store)
        guard let project = try store.project(id: request.projectID) else { return SpacesDeviceAPIResponse(ok: false, message: "Project not found.") }
        try orchestrator.removeProject(dir: project.dir)
        return try refreshedMutationResponse(message: "Deleted project '\(project.name)'.")
    }

    private func handleImportProjectRequest(_ request: SpacesDeviceProjectImportRequest) throws -> SpacesDeviceAPIResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        _ = try deviceOrchestrator(store: store).importSpacesYAML(projectID: request.projectID, updateAllWorkspaces: request.updateAllWorkspaces)
        return try refreshedMutationResponse(message: "Imported spaces.yaml.", projectID: request.projectID)
    }

    private func handleExportProjectRequest(_ request: SpacesDeviceProjectReference) throws -> SpacesDeviceAPIResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let url = try deviceOrchestrator(store: store).exportSpacesYAML(projectID: request.projectID)
        return try refreshedMutationResponse(message: "Exported spaces.yaml to \(url.path).", projectID: request.projectID)
    }

    private func handleCreateWorkspaceRequest(_ request: SpacesDeviceWorkspaceCreateRequest) throws -> SpacesDeviceAPIResponse {
        let projectID = request.projectID
        let title = request.title
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let orchestrator = deviceOrchestrator(store: store)
        let project = try store.project(id: projectID)
        let workspace = try orchestrator.createWorkspace(
            projectID: projectID, name: title, branch: normalizedString(request.branch), targetBranch: normalizedString(request.targetBranch),
            directoryName: normalizedString(request.directoryName), runSetupScript: true, allowRemoteBranchLookup: true,
            allowExistingBranchReuse: request.allowExistingBranchReuse)
        if let notes = normalizedOptionalString(request.notes) { try orchestrator.updateWorkspaceNotes(workspaceID: workspace.id, notes: notes) }
        let message = "Created workspace '\(workspace.title)'\(project.map { " in \($0.name)" } ?? "")."
        return try refreshedMutationResponse(message: message, workspaceID: workspace.id)
    }

    private func handleLaunchWorkspaceRequest(_ request: SpacesDeviceWorkspaceLifecycleRequest) throws -> SpacesDeviceAPIResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        try deviceOrchestrator(store: store).launchWorkspace(workspaceID: request.workspaceID)
        return try refreshedMutationResponse(message: "Launched workspace.", workspaceID: request.workspaceID)
    }

    private func handleStopWorkspaceRequest(_ request: SpacesDeviceWorkspaceLifecycleRequest) throws -> SpacesDeviceAPIResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        _ = try deviceOrchestrator(store: store).stopWorkspace(workspaceID: request.workspaceID)
        return try refreshedMutationResponse(message: "Stopped workspace.", workspaceID: request.workspaceID)
    }

    private func handleRestartWorkspaceRequest(_ request: SpacesDeviceWorkspaceLifecycleRequest) throws -> SpacesDeviceAPIResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        try deviceOrchestrator(store: store).upWorkspace(workspaceID: request.workspaceID, restartIfRunning: true, background: true)
        return try refreshedMutationResponse(message: "Restarted workspace.", workspaceID: request.workspaceID)
    }

    private func handleArchiveWorkspaceRequest(_ request: SpacesDeviceWorkspaceArchiveRequest) throws -> SpacesDeviceAPIResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        _ = try deviceOrchestrator(store: store).archiveWorkspace(
            workspaceID: request.workspaceID, deleteLocalBranch: request.deleteLocalBranch, deleteRemoteBranch: request.deleteRemoteBranch)
        return try refreshedMutationResponse(message: "Archived workspace.", workspaceID: request.workspaceID)
    }

    private func handleRunWorkspaceSetupRequest(_ request: SpacesDeviceWorkspaceReference) throws -> SpacesDeviceAPIResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        try deviceOrchestrator(store: store).runWorkspaceSetup(workspaceID: request.workspaceID)
        return try refreshedMutationResponse(message: "Ran workspace setup.", workspaceID: request.workspaceID)
    }

    private func handleUpdateProjectConfigRequest(_ request: SpacesDeviceProjectConfigUpdateRequest) throws -> SpacesDeviceAPIResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        try deviceOrchestrator(store: store).updateProjectConfig(projectID: request.projectID, updateAllWorkspaces: request.updateAllWorkspaces) {
            config in
            config.setupScript = normalizedOptionalString(request.config.setupScript)
            config.stopScript = normalizedOptionalString(request.config.stopScript)
            config.ports = request.config.ports.map(workspacePort)
            config.processes = request.config.processes.map(workspaceProcess)
            config.browserSessions = request.config.browserSessions.map(workspaceBrowserSession)
            config.agentLaunchers = request.config.agentLaunchers.map(workspaceAgentLauncher)
        }
        return try refreshedMutationResponse(message: "Updated project settings.", projectID: request.projectID)
    }

    private func handleUpdateWorkspaceConfigRequest(_ request: SpacesDeviceWorkspaceConfigUpdateRequest) throws -> SpacesDeviceAPIResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        try deviceOrchestrator(store: store).updateWorkspaceSettings(workspaceID: request.workspaceID) { config in
            config.stopScript = normalizedOptionalString(request.config.stopScript)
            config.ports = request.config.ports.map(workspacePort)
            config.processes = request.config.processes.map(workspaceProcess)
            config.browserSessions = request.config.browserSessions.map(workspaceBrowserSession)
            config.agentLaunchers = request.config.agentLaunchers.map(workspaceAgentLauncher)
        }
        return try refreshedMutationResponse(message: "Updated workspace settings.", workspaceID: request.workspaceID)
    }

    private func handleUpdateWorkspaceMetadataRequest(_ request: SpacesDeviceWorkspaceMetadataUpdateRequest) throws -> SpacesDeviceAPIResponse {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let orchestrator = deviceOrchestrator(store: store)
        if request.updatesTitle {
            guard let title = normalizedString(request.title) else {
                return SpacesDeviceAPIResponse(ok: false, message: "Workspace title is required.")
            }
            try orchestrator.updateWorkspaceName(workspaceID: request.workspaceID, name: title)
        }
        if request.updatesBranch {
            try orchestrator.updateWorkspaceMetadata(workspaceID: request.workspaceID, branch: normalizedString(request.branch) ?? "")
        }
        if request.updatesNotes {
            try orchestrator.updateWorkspaceNotes(workspaceID: request.workspaceID, notes: normalizedOptionalString(request.notes))
        }
        if request.updatesHidden { try orchestrator.updateWorkspaceHidden(workspaceID: request.workspaceID, isHidden: request.isHidden == true) }
        return try refreshedMutationResponse(message: "Updated workspace metadata.", workspaceID: request.workspaceID)
    }

    private func handleOpenWorkspaceTerminalRequest(_ request: SpacesDeviceWorkspaceReference) throws -> SpacesDeviceAPIResponse {
        let workspaceID = request.workspaceID
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let sessionID = try deviceOrchestrator(store: store).openWorkspaceTerminal(workspaceID: workspaceID)
        return try refreshedMutationResponse(message: "Opened workspace terminal.", workspaceID: workspaceID, sessionID: sessionID)
    }

    private func handleStopWorkspaceTerminalRequest(_ request: SpacesDeviceWorkspaceTerminalRequest) throws -> SpacesDeviceAPIResponse {
        let workspaceID = request.workspaceID
        let sessionID = request.sessionID
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        guard try deviceOrchestrator(store: store).stopAdHocBuiltInTerminalSession(workspaceID: workspaceID, sessionID: sessionID) else {
            return try refreshedMutationResponse(message: "Workspace terminal was already stopped.", workspaceID: workspaceID)
        }
        return try refreshedMutationResponse(message: "Stopped workspace terminal.", workspaceID: workspaceID)
    }

    private func handleRunWorkspaceProcessRequest(_ request: SpacesDeviceRunWorkspaceProcessRequest) throws -> SpacesDeviceAPIResponse {
        let workspaceID = request.workspaceID
        let processKey = request.processKey
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        if let processTemplateID = normalizedString(request.processTemplateID) {
            try deviceOrchestrator(store: store).runConfiguredProcess(
                workspaceID: workspaceID, processTemplateID: processTemplateID, processKey: processKey)
        } else {
            try deviceOrchestrator(store: store).runConfiguredProcess(workspaceID: workspaceID, processKey: processKey)
        }
        return try refreshedMutationResponse(message: "Ran process '\(processKey)'.", workspaceID: workspaceID)
    }

    private func handleStopWorkspaceProcessRequest(_ request: SpacesDeviceWorkspaceProcessMutationRequest) throws -> SpacesDeviceAPIResponse {
        let workspaceID = request.workspaceID
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let processID = try resolvedRunningProcessID(request: request, store: store)
        try deviceOrchestrator(store: store).stopWorkspaceProcess(workspaceID: workspaceID, processID: processID)
        return try refreshedMutationResponse(message: "Stopped process.", workspaceID: workspaceID)
    }

    private func handleRestartWorkspaceProcessRequest(_ request: SpacesDeviceWorkspaceProcessMutationRequest) throws -> SpacesDeviceAPIResponse {
        let workspaceID = request.workspaceID
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let processID = try resolvedRunningProcessID(request: request, store: store)
        try deviceOrchestrator(store: store).restartWorkspaceProcess(workspaceID: workspaceID, processID: processID)
        return try refreshedMutationResponse(message: "Restarted process.", workspaceID: workspaceID)
    }

    private func handleRunCodingAgentRequest(_ request: SpacesDeviceRunCodingAgentRequest) throws -> SpacesDeviceAPIResponse {
        let workspaceID = request.workspaceID
        let agentName = request.agentName
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let record =
            if let agentLauncherID = normalizedString(request.agentLauncherID) {
                try deviceOrchestrator(store: store).launchAgentLauncher(workspaceID: workspaceID, launcherID: agentLauncherID)
            } else { try deviceOrchestrator(store: store).launchAgentLauncher(workspaceID: workspaceID, name: agentName) }
        return try refreshedMutationResponse(
            message: "Ran coding agent '\(agentName)'.", workspaceID: workspaceID,
            sessionID: normalizedString(record.terminalNativeID ?? record.terminalTrackingID))
    }

    private func handleStopCodingAgentRequest(_ request: SpacesDeviceCodingAgentMutationRequest) throws -> SpacesDeviceAPIResponse {
        let workspaceID = request.workspaceID
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        guard let agentID = try resolvedAgentID(request: request, store: store) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Missing coding agent ID.")
        }
        try deviceOrchestrator(store: store).stopCodingAgent(workspaceID: workspaceID, agentID: agentID)
        return try refreshedMutationResponse(message: "Stopped coding agent.", workspaceID: workspaceID)
    }

    private func handleRestartCodingAgentRequest(_ request: SpacesDeviceCodingAgentMutationRequest) throws -> SpacesDeviceAPIResponse {
        let workspaceID = request.workspaceID
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        guard let agentID = try resolvedAgentID(request: request, store: store) else {
            return SpacesDeviceAPIResponse(ok: false, message: "Missing coding agent ID.")
        }
        let record = try deviceOrchestrator(store: store).restartCodingAgent(workspaceID: workspaceID, agentID: agentID)
        return try refreshedMutationResponse(
            message: "Restarted coding agent.", workspaceID: workspaceID,
            sessionID: normalizedString(record.terminalNativeID ?? record.terminalTrackingID))
    }

    private func refreshedMutationResponse(message: String, projectID: String? = nil, workspaceID: String? = nil, sessionID: String? = nil) throws
        -> SpacesDeviceAPIResponse
    {
        SpacesDeviceAPIResponse(
            ok: true, message: message,
            result: .mutation(
                SpacesDeviceMutationResult(overview: try loadOverview(), projectID: projectID, workspaceID: workspaceID, sessionID: sessionID)))
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

    private func workspacePort(_ port: SpacesDevicePortDefinition) -> PortDefinition { PortDefinition(id: port.id, name: port.name) }

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

    private func handleResolveTerminalLinkRequest(_ request: SpacesDeviceTerminalLinkResolveRequest) throws -> SpacesDeviceAPIResponse {
        let sessionID = request.sessionID
        pruneTerminalLinkTransferAuthorizations(now: Date())
        let metadata: SpacesDeviceTerminalLinkMetadata
        if canResolveTerminalLinkWithoutLocalState(request.terminalLink) {
            metadata = try SpacesDeviceTerminalLinkResolver.resolve(
                sessionID: sessionID, link: request.terminalLink, workingDirectory: nil, workspaceRoots: [])
        } else {
            let workspaceRoots = try loadWorkspaceRoots()
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

    private func loadWorkspaceRoots() throws -> [String] {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
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
            guard let sessionID = request.sessionID else { return .response(SpacesDeviceAPIResponse(ok: false, message: "Missing session ID.")) }
            guard let installationID = request.clientApp?.installationID.trimmingCharacters(in: .whitespacesAndNewlines), !installationID.isEmpty
            else { return .response(SpacesDeviceAPIResponse(ok: false, message: "Missing client installation ID.")) }
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            if let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), !runtimeState.state.isInteractive {
                let payload =
                    (try? TerminalSessionPersistence.readRemoteSessionState(paths: paths))
                    ?? (try? endedStatePayload(sessionID: sessionID, paths: paths, runtimeState: runtimeState))
                if let payload { return .finalPayload(payload) }
                return .response(SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' has no final state."))
            }
            guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
                return .response(SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' has no live state stream."))
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
                        request: TerminalControlRequest(command: "heartbeat", clientID: clientID), socketPath: controlSocketPath)
                }
                heartbeatTimer = timer
                timer.resume()
            } else {
                heartbeatTimer = nil
            }
            defer { heartbeatTimer?.cancel() }

            let startedAt = Date()
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
                    try LinuxServer.writeTLSResponse(Data(bytes: baseAddress, count: count), ssl: ssl)
                }
            }
            TerminalPerformance.logMetric(
                "device_api_subscribe", target: "session=\(subscription.sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
                success: true)
        }
    #endif

    #if canImport(Network) && canImport(Security)
        private func handleSubscribeRequest(_ request: SpacesDeviceAPIRequest, connection: NWConnection) throws {
            guard let sessionID = request.sessionID else {
                sendResponse(SpacesDeviceAPIResponse(ok: false, message: "Missing session ID."), to: connection) { _ in connection.cancel() }
                return
            }
            guard let installationID = request.clientApp?.installationID.trimmingCharacters(in: .whitespacesAndNewlines), !installationID.isEmpty
            else {
                sendResponse(SpacesDeviceAPIResponse(ok: false, message: "Missing client installation ID."), to: connection) { _ in
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
                    sendResponse(SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' has no final state."), to: connection) {
                        _ in connection.cancel()
                    }
                }
                return
            }
            guard FileManager.default.fileExists(atPath: paths.subscriptionSocketPath) else {
                sendResponse(SpacesDeviceAPIResponse(ok: false, message: "Terminal session '\(sessionID)' has no live state stream."), to: connection)
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
                        request: TerminalControlRequest(command: "heartbeat", clientID: clientID), socketPath: paths.controlSocketPath)
                }
                heartbeatTimer = timer
            } else {
                heartbeatTimer = nil
            }

            streamRelays[ObjectIdentifier(connection)] = StreamRelay(
                sessionID: sessionID, installationID: installationID, relaySocketFD: relaySocketFD, relayQueue: relayQueue, relaySource: relaySource,
                heartbeatTimer: heartbeatTimer, connection: connection, sendSequencer: StreamSendSequencer())

            relaySource.resume()
            heartbeatTimer?.resume()

            TerminalPerformance.logMetric(
                "device_api_subscribe", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true)
        }
    #endif

    #if canImport(Network) && canImport(Security)
        private func sendStreamPayloadAndComplete(_ payload: GhosttyRemoteSessionStatePayload, sessionID: String, to connection: NWConnection) {
            do {
                let data = try GhosttyRemoteSessionStateCodec.encodeLine(payload)
                let attributes = streamRelayAttributes(for: data)
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
                sendResponse(SpacesDeviceAPIResponse(ok: false, message: String(describing: error)), to: connection) { _ in connection.cancel() }
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
            let attributes = streamRelayAttributes(for: data)
            logDeviceAPIPerformance(
                sessionID: relay.sessionID, name: "stream_relay_read",
                emittedUptimeNanoseconds: firstReadUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds, count: data.count,
                attributes: attributes)
            relay.sendSequencer.enqueue { [weak self, weak connection, sessionID = relay.sessionID, attributes, data, closeAfterSend] finish in
                guard let self, let connection else {
                    finish(nil)
                    return
                }
                self.networkShaper.send(
                    content: data, to: connection, on: self.queue,
                    onSendBegin: { [weak self, sessionID, attributes, count = data.count] in
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

        private func streamRelayAttributes(for data: Data) -> [String: String] {
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
        sessionID: String, name: String, emittedUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds, count: Int? = nil,
        attributes: [String: String] = [:]
    ) {
        SpacesDeviceTerminalPerformanceLogger.emit(
            .init(
                sessionID: sessionID, source: "device-api", name: name, emittedUptimeNanoseconds: emittedUptimeNanoseconds, count: count,
                attributes: attributes))
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        running = value
        stateLock.unlock()
    }
}
