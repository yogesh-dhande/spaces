import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#endif
#if canImport(Glibc)
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

public enum SpacesPinnedTLSConnectionError: LocalizedError {
    case invalidPort(Int)
    case timeout
    case connectionClosed
    case connectionFailed(String)
    case receiveLoopActive

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port): "The pinned TLS port is invalid: \(port)."
        case .timeout: "Timed out waiting for the pinned TLS peer."
        case .connectionClosed: "The pinned TLS connection was closed."
        case .connectionFailed(let message): "The pinned TLS connection failed: \(message)"
        case .receiveLoopActive: "The pinned TLS connection is already streaming."
        }
    }
}

/// One newline-framed pinned-TLS client connection. `sendLine`/`readLine` drive request-response
/// exchanges; `startReceiveLoop` switches the connection to streaming delivery (after which
/// `readLine` must not be used). Lines are JSON documents without the trailing newline; `sendLine`
/// appends the frame delimiter.
public protocol SpacesPinnedTLSLineConnection: AnyObject, Sendable {
    func sendLine(_ line: Data, timeout: TimeInterval) throws
    func readLine(timeout: TimeInterval) throws -> Data
    func startReceiveLoop(onLine: @escaping @Sendable (Data) -> Void, onClosed: @escaping @Sendable ((any Error)?) -> Void)
    func cancel()
}

/// Opens pinned-TLS client connections with a platform backend behind one wire contract:
/// TLS 1.2+, the server's leaf certificate must match the expected `SHA256:<hex>` fingerprint
/// before any application byte is exchanged, and frames are newline-delimited. Darwin uses
/// Network.framework; Linux uses OpenSSL. Both produce byte-identical traffic.
public enum SpacesPinnedTLSConnector {
    public static func connect(host: String, port: Int, certificateFingerprint: String, timeout: TimeInterval = 10) throws
        -> any SpacesPinnedTLSLineConnection
    {
        let expectedFingerprint = certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedFingerprint.isEmpty else { throw TerminalServiceTLSError.missingCertificateFingerprint }
        guard UInt16(exactly: port) != nil, port > 0 else { throw SpacesPinnedTLSConnectionError.invalidPort(port) }
        #if canImport(Network) && canImport(Security)
            return try DarwinPinnedTLSConnection(host: host, port: port, expectedFingerprint: expectedFingerprint, timeout: timeout)
        #elseif os(Linux) && canImport(OpenSSL)
            return try OpenSSLPinnedTLSConnection(host: host, port: port, expectedFingerprint: expectedFingerprint, timeout: timeout)
        #else
            throw SpacesPinnedTLSConnectionError.connectionFailed("No pinned TLS backend is available on this platform.")
        #endif
    }

    /// True when an error means the peer closed or dropped the connection, so an idempotent
    /// request may be replayed on a fresh connection.
    public static func isClosedConnectionError(_ error: any Error) -> Bool {
        if case SpacesPinnedTLSConnectionError.connectionClosed = error { return true }
        let description = String(describing: error)
        return description.localizedStandardContains("connection was cancelled") || description.localizedStandardContains("connection was aborted")
            || description.localizedStandardContains("connection reset") || description.localizedStandardContains("posixerrorcode: 54")
            || description.localizedStandardContains("broken pipe")
    }
}

#if canImport(Network) && canImport(Security)
    extension SpacesPinnedTLSConnector {
        /// The same pin policy as `connect`, packaged as NWParameters for Apple-platform callers
        /// that manage their own NWConnections (the iOS Device API client). Deliberately no
        /// pin-failure reason plumbing: these callers classify a pin failure as a failed or
        /// stalled handshake on their own state handler (the iOS client distinguishes it from an
        /// unreachable host with a plain-TCP probe). The shared factory still traces the specific
        /// reason for diagnostics.
        public static func tlsParameters(certificateFingerprint: String) -> NWParameters {
            let expectedFingerprint = certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            return TerminalServicePinnedTLS.makePinnedTLSParameters(expectedFingerprint: expectedFingerprint, pinFailure: { _ in })
        }
    }

    private final class DarwinPinnedTLSConnection: SpacesPinnedTLSLineConnection, @unchecked Sendable {
        private let queue = DispatchQueue(label: "spaces.pinned.tls.connection")
        private let stateLock = NSLock()
        private var connection: NWConnection?
        private var readBuffer = LineFrameBuffer()
        private var streaming = false

        init(host: String, port: Int, expectedFingerprint: String, timeout: TimeInterval) throws {
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw SpacesPinnedTLSConnectionError.invalidPort(port) }
            let ready = DispatchSemaphore(value: 0)
            let pinBox = TransportResultBox()
            let parameters = TerminalServicePinnedTLS.makePinnedTLSParameters(
                expectedFingerprint: expectedFingerprint,
                pinFailure: { error in
                    pinBox.setErrorIfUnset(error)
                    ready.signal()
                })

            let createdConnection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
            createdConnection.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.signal()
                case .failed(let error):
                    if pinBox.error() == nil { pinBox.setErrorIfUnset(SpacesPinnedTLSConnectionError.connectionFailed(String(describing: error))) }
                    ready.signal()
                default: break
                }
            }
            createdConnection.start(queue: queue)
            guard ready.wait(timeout: .now() + timeout) == .success else {
                createdConnection.cancel()
                throw pinBox.error() ?? SpacesPinnedTLSConnectionError.timeout
            }
            if let error = pinBox.error() {
                createdConnection.cancel()
                throw error
            }
            connection = createdConnection
        }

        deinit { cancel() }

        func cancel() {
            stateLock.lock()
            let activeConnection = connection
            connection = nil
            stateLock.unlock()
            activeConnection?.cancel()
        }

        private func activeConnection() throws -> NWConnection {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard let connection else { throw SpacesPinnedTLSConnectionError.connectionClosed }
            return connection
        }

        func sendLine(_ line: Data, timeout: TimeInterval) throws {
            let connection = try activeConnection()
            var payload = line
            payload.append(0x0A)
            let sent = DispatchSemaphore(value: 0)
            let errorBox = TransportResultBox()
            connection.send(
                content: payload, contentContext: .defaultMessage, isComplete: false,
                completion: .contentProcessed { error in
                    if let error { errorBox.setErrorIfUnset(SpacesPinnedTLSConnectionError.connectionFailed(String(describing: error))) }
                    sent.signal()
                })
            guard sent.wait(timeout: .now() + timeout) == .success else { throw SpacesPinnedTLSConnectionError.timeout }
            if let error = errorBox.error() { throw error }
        }

        func readLine(timeout: TimeInterval) throws -> Data {
            let connection = try activeConnection()
            if let line = popBufferedLine() { return line }
            let received = DispatchSemaphore(value: 0)
            let resultBox = SpacesPinnedTLSLineBox()
            receiveLine(on: connection, resultBox: resultBox, completion: received)
            guard received.wait(timeout: .now() + timeout) == .success else { throw SpacesPinnedTLSConnectionError.timeout }
            return try resultBox.value()
        }

        private func popBufferedLine() -> Data? {
            stateLock.lock()
            defer { stateLock.unlock() }
            return readBuffer.popLine()
        }

        private func receiveLine(on connection: NWConnection, resultBox: SpacesPinnedTLSLineBox, completion: DispatchSemaphore) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [self] content, _, isComplete, error in
                if let error {
                    resultBox.set(.failure(SpacesPinnedTLSConnectionError.connectionFailed(String(describing: error))))
                    completion.signal()
                    return
                }
                stateLock.lock()
                if let content, !content.isEmpty { readBuffer.append(content) }
                if let line = readBuffer.popLine() {
                    stateLock.unlock()
                    resultBox.set(.success(line))
                    completion.signal()
                    return
                }
                if isComplete {
                    guard !readBuffer.isEmpty else {
                        stateLock.unlock()
                        resultBox.set(.failure(SpacesPinnedTLSConnectionError.connectionClosed))
                        completion.signal()
                        return
                    }
                    let line = readBuffer.drainRemainder()
                    stateLock.unlock()
                    resultBox.set(.success(line))
                    completion.signal()
                    return
                }
                stateLock.unlock()
                receiveLine(on: connection, resultBox: resultBox, completion: completion)
            }
        }

        func startReceiveLoop(onLine: @escaping @Sendable (Data) -> Void, onClosed: @escaping @Sendable ((any Error)?) -> Void) {
            stateLock.lock()
            guard !streaming, let connection else {
                let wasStreaming = streaming
                stateLock.unlock()
                onClosed(wasStreaming ? SpacesPinnedTLSConnectionError.receiveLoopActive : SpacesPinnedTLSConnectionError.connectionClosed)
                return
            }
            streaming = true
            stateLock.unlock()
            receiveNextStreamLine(on: connection, onLine: onLine, onClosed: onClosed)
        }

        private func receiveNextStreamLine(
            on connection: NWConnection, onLine: @escaping @Sendable (Data) -> Void, onClosed: @escaping @Sendable ((any Error)?) -> Void
        ) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [self] content, _, isComplete, error in
                if let error {
                    stateLock.lock()
                    let cancelled = self.connection == nil
                    stateLock.unlock()
                    onClosed(cancelled ? nil : SpacesPinnedTLSConnectionError.connectionFailed(String(describing: error)))
                    return
                }
                stateLock.lock()
                if let content, !content.isEmpty { readBuffer.append(content) }
                var lines: [Data] = []
                while let line = readBuffer.popLine() { if !line.isEmpty { lines.append(line) } }
                stateLock.unlock()
                for line in lines { onLine(line) }
                if isComplete {
                    onClosed(nil)
                    return
                }
                receiveNextStreamLine(on: connection, onLine: onLine, onClosed: onClosed)
            }
        }
    }

    private final class SpacesPinnedTLSLineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedResult: Result<Data, any Error>?

        func set(_ result: Result<Data, any Error>) {
            lock.lock()
            storedResult = result
            lock.unlock()
        }

        func value() throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            return try storedResult?.get() ?? Data()
        }
    }
#endif

#if os(Linux) && canImport(OpenSSL)
    private final class OpenSSLPinnedTLSConnection: SpacesPinnedTLSLineConnection, @unchecked Sendable {
        private let stateLock = NSLock()
        private let transferLock = NSLock()
        private var socketFD: Int32 = -1
        private var ssl: OpaquePointer?
        private var sslContext: OpaquePointer?
        private var readBuffer = LineFrameBuffer()
        private var cancelled = false
        private var streaming = false

        init(host: String, port: Int, expectedFingerprint: String, timeout: TimeInterval) throws {
            OPENSSL_init_ssl(0, nil)
            let fd = try Self.connectTCP(host: host, port: port, timeout: timeout)
            var contextPointer: OpaquePointer?
            var sslPointer: OpaquePointer?
            do {
                guard let method = TLS_client_method(), let context = SSL_CTX_new(method) else {
                    throw SpacesPinnedTLSConnectionError.connectionFailed(Self.openSSLErrorMessage("failed to create TLS context"))
                }
                contextPointer = context
                guard spaces_SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) == 1 else {
                    throw SpacesPinnedTLSConnectionError.connectionFailed(Self.openSSLErrorMessage("failed to configure minimum TLS version"))
                }
                guard let created = SSL_new(context) else {
                    throw SpacesPinnedTLSConnectionError.connectionFailed(Self.openSSLErrorMessage("failed to create SSL session"))
                }
                sslPointer = created
                SSL_set_fd(created, fd)
                Self.setSocketTimeout(fd, seconds: timeout)
                guard SSL_connect(created) == 1 else {
                    throw SpacesPinnedTLSConnectionError.connectionFailed(Self.openSSLErrorMessage("TLS handshake failed"))
                }
                // The pin decides trust: verify the leaf certificate digest before any application
                // byte is written, mirroring the Darwin verify-block ordering.
                var digest = [UInt8](repeating: 0, count: 32)
                guard spaces_SSL_peer_certificate_sha256(created, &digest) == 1 else { throw TerminalServiceTLSError.peerCertificateUnavailable }
                let actualFingerprint = "SHA256:\(digest.map { String(format: "%02x", $0) }.joined())"
                guard TerminalServiceTLSFingerprint.matches(expectedFingerprint, actualFingerprint) else {
                    throw TerminalServiceTLSError.certificatePinMismatch(expected: expectedFingerprint, actual: actualFingerprint)
                }
            } catch {
                if let sslPointer {
                    SSL_shutdown(sslPointer)
                    SSL_free(sslPointer)
                }
                if let contextPointer { SSL_CTX_free(contextPointer) }
                close(fd)
                throw error
            }
            socketFD = fd
            ssl = sslPointer
            sslContext = contextPointer
        }

        deinit { cancel() }

        func cancel() {
            stateLock.lock()
            if cancelled {
                stateLock.unlock()
                return
            }
            cancelled = true
            let fd = socketFD
            stateLock.unlock()
            // Unblock any in-flight SSL_read before tearing the session down.
            if fd >= 0 { shutdown(fd, Int32(SHUT_RDWR)) }
            transferLock.lock()
            stateLock.lock()
            if let ssl {
                SSL_free(ssl)
                self.ssl = nil
            }
            if let sslContext {
                SSL_CTX_free(sslContext)
                self.sslContext = nil
            }
            if socketFD >= 0 {
                close(socketFD)
                socketFD = -1
            }
            stateLock.unlock()
            transferLock.unlock()
        }

        private func activeSSL() throws -> (ssl: OpaquePointer, fd: Int32) {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !cancelled, let ssl, socketFD >= 0 else { throw SpacesPinnedTLSConnectionError.connectionClosed }
            return (ssl, socketFD)
        }

        func sendLine(_ line: Data, timeout: TimeInterval) throws {
            transferLock.lock()
            defer { transferLock.unlock() }
            let (ssl, fd) = try activeSSL()
            Self.setSocketTimeout(fd, seconds: timeout)
            var payload = line
            payload.append(0x0A)
            try payload.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var bytesRemaining = rawBuffer.count
                var offset = 0
                while bytesRemaining > 0 {
                    let chunkSize = min(bytesRemaining, Int(Int32.max))
                    let written = SSL_write(ssl, baseAddress.advanced(by: offset), Int32(chunkSize))
                    guard written > 0 else { throw try self.readWriteFailure(ssl: ssl, result: written, operation: "write") }
                    bytesRemaining -= Int(written)
                    offset += Int(written)
                }
            }
        }

        func readLine(timeout: TimeInterval) throws -> Data {
            transferLock.lock()
            defer { transferLock.unlock() }
            let (ssl, fd) = try activeSSL()
            Self.setSocketTimeout(fd, seconds: timeout)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                if let line = readBuffer.popLine() { return line }
                let count = SSL_read(ssl, &buffer, Int32(buffer.count))
                if count > 0 {
                    readBuffer.append(Data(buffer[..<Int(count)]))
                    continue
                }
                if SSL_get_error(ssl, count) == SSL_ERROR_ZERO_RETURN {
                    guard !readBuffer.isEmpty else { throw SpacesPinnedTLSConnectionError.connectionClosed }
                    return readBuffer.drainRemainder()
                }
                throw try readWriteFailure(ssl: ssl, result: count, operation: "read")
            }
        }

        func startReceiveLoop(onLine: @escaping @Sendable (Data) -> Void, onClosed: @escaping @Sendable ((any Error)?) -> Void) {
            stateLock.lock()
            guard !streaming, !cancelled, socketFD >= 0 else {
                let wasStreaming = streaming
                stateLock.unlock()
                onClosed(wasStreaming ? SpacesPinnedTLSConnectionError.receiveLoopActive : SpacesPinnedTLSConnectionError.connectionClosed)
                return
            }
            streaming = true
            // Streaming reads block indefinitely; cancel() unblocks them via shutdown(2).
            Self.setSocketTimeout(socketFD, seconds: 0)
            stateLock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { [self] in runReceiveLoop(onLine: onLine, onClosed: onClosed) }
        }

        private func runReceiveLoop(onLine: @escaping @Sendable (Data) -> Void, onClosed: @escaping @Sendable ((any Error)?) -> Void) {
            transferLock.lock()
            defer { transferLock.unlock() }
            guard let (ssl, _) = try? activeSSL() else {
                onClosed(nil)
                return
            }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                while let line = readBuffer.popLine() { if !line.isEmpty { onLine(line) } }
                let count = SSL_read(ssl, &buffer, Int32(buffer.count))
                if count > 0 {
                    readBuffer.append(Data(buffer[..<Int(count)]))
                    continue
                }
                stateLock.lock()
                let wasCancelled = cancelled
                stateLock.unlock()
                if wasCancelled || SSL_get_error(ssl, count) == SSL_ERROR_ZERO_RETURN {
                    onClosed(nil)
                    return
                }
                onClosed(SpacesPinnedTLSConnectionError.connectionFailed(Self.openSSLErrorMessage("failed to read TLS stream")))
                return
            }
        }

        private func readWriteFailure(ssl: OpaquePointer, result: Int32, operation: String) throws -> any Error {
            stateLock.lock()
            let wasCancelled = cancelled
            stateLock.unlock()
            if wasCancelled { return SpacesPinnedTLSConnectionError.connectionClosed }
            let sslError = SSL_get_error(ssl, result)
            if sslError == SSL_ERROR_SYSCALL, errno == EAGAIN || errno == EWOULDBLOCK { return SpacesPinnedTLSConnectionError.timeout }
            return SpacesPinnedTLSConnectionError.connectionFailed(Self.openSSLErrorMessage("failed to \(operation) TLS data"))
        }

        private static func connectTCP(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
            var results: UnsafeMutablePointer<addrinfo>?
            let resolution = getaddrinfo(host, String(port), &hints, &results)
            guard resolution == 0, let first = results else {
                throw SpacesPinnedTLSConnectionError.connectionFailed("Could not resolve host \(host): \(String(cString: gai_strerror(resolution)))")
            }
            defer { freeaddrinfo(results) }

            var lastError: any Error = SpacesPinnedTLSConnectionError.connectionFailed("Could not connect to \(host):\(port).")
            var candidate: UnsafeMutablePointer<addrinfo>? = first
            while let info = candidate {
                candidate = info.pointee.ai_next
                let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
                guard fd >= 0 else {
                    lastError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    continue
                }
                do {
                    try connectWithTimeout(fd: fd, address: info.pointee.ai_addr, addressLength: info.pointee.ai_addrlen, timeout: timeout)
                    try setCloseOnExec(fd)
                    SpacesTCPKeepalive.apply(to: fd)
                    return fd
                } catch {
                    lastError = error
                    close(fd)
                }
            }
            throw lastError
        }

        private static func connectWithTimeout(fd: Int32, address: UnsafeMutablePointer<sockaddr>?, addressLength: socklen_t, timeout: TimeInterval)
            throws
        {
            try setNonBlocking(fd)
            let result = connect(fd, address, addressLength)
            if result != 0 {
                guard errno == EINPROGRESS else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let pollResult = poll(&pollDescriptor, 1, Int32(timeout * 1000))
                guard pollResult > 0 else {
                    throw pollResult == 0 ? SpacesPinnedTLSConnectionError.timeout : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: socketError) ?? .EIO)
                }
            }
            try setBlocking(fd)
        }

        private static func setNonBlocking(_ fileDescriptor: Int32) throws {
            let currentFlags = fcntl(fileDescriptor, F_GETFL)
            guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        private static func setBlocking(_ fileDescriptor: Int32) throws {
            let currentFlags = fcntl(fileDescriptor, F_GETFL)
            guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard fcntl(fileDescriptor, F_SETFL, currentFlags & ~O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        private static func setCloseOnExec(_ fileDescriptor: Int32) throws {
            let currentFlags = fcntl(fileDescriptor, F_GETFD)
            guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard fcntl(fileDescriptor, F_SETFD, currentFlags | FD_CLOEXEC) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        private static func setSocketTimeout(_ fileDescriptor: Int32, seconds: TimeInterval) {
            var value = timeval(tv_sec: Int(seconds.rounded(.down)), tv_usec: Int(seconds.truncatingRemainder(dividingBy: 1) * 1_000_000))
            setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        }

        private static func openSSLErrorMessage(_ prefix: String) -> String {
            let code = ERR_get_error()
            guard code != 0, let message = ERR_error_string(code, nil) else { return prefix }
            return "\(prefix): \(String(cString: message))"
        }
    }
#endif
