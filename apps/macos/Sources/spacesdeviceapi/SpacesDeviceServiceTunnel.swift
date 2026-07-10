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

extension SpacesDeviceAPIServer {
    /// Hard ceiling on concurrently open service tunnels across all clients. Each tunnel pins a
    /// loopback socket plus (on Darwin) a dispatch source and relay queue; the cap bounds that fan-out
    /// so a misbehaving or compromised paired client cannot exhaust file descriptors.
    static let maxConcurrentServiceTunnels = 64

    /// Per-read buffer for the raw byte pipe in both directions. Matches the terminal stream relay's
    /// read size so a single readable event drains a full socket buffer.
    static let serviceTunnelBufferSize = 256 * 1024
}

/// Outcome of resolving a service-tunnel request to a concrete loopback port. `failure` carries the
/// exact response the daemon should return before closing the connection.
enum SpacesDeviceServiceTunnelResolution: Sendable {
    case port(Int)
    case failure(message: String, errorCode: SpacesDeviceErrorCode)
}

/// Resolves an `openServiceTunnel` request against the daemon's own database: the workspace must exist
/// and the named service must have an assigned port. This opens its own `SQLiteStore`, matching how the
/// server's other database-backed paths access the store off the shared request context.
enum SpacesDeviceServiceTunnelResolver {
    static func resolve(_ request: SpacesDeviceServiceTunnelRequest) throws -> SpacesDeviceServiceTunnelResolution {
        let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
        let workspaceID = request.workspaceID
        guard try store.workspace(id: workspaceID) != nil else {
            return .failure(message: "Workspace '\(workspaceID)' was not found.", errorCode: .notFound)
        }
        let serviceName = request.serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let assigned = try store.workspacePortsNamed(workspaceID: workspaceID)
        guard let match = assigned.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == serviceName }) else {
            return .failure(message: "Service '\(serviceName)' was not found in workspace '\(workspaceID)'.", errorCode: .notFound)
        }
        return .port(match.port)
    }
}

/// Dials a workspace service on `127.0.0.1:<port>` with a bounded, non-blocking connect so a service
/// that is configured but not listening fails fast (mapped to `.serviceNotRunning`) instead of hanging
/// the request connection.
enum SpacesDeviceServiceTunnelDialer {
    /// - Parameter blocking: whether to leave the returned socket in blocking mode. Darwin drives the
    ///   phone→service direction with blocking writes on a dedicated queue; the Linux splice loop needs
    ///   the socket non-blocking for its `poll(2)` loop.
    static func dialLoopback(port: Int, timeoutSeconds: TimeInterval = 2, blocking: Bool = true) throws -> Int32 {
        let fileDescriptor = socket(AF_INET, streamSocketType, 0)
        guard fileDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        #if canImport(Darwin)
            var noSIGPIPE: Int32 = 1
            setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        #endif
        do {
            try setNonBlocking(fileDescriptor)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
            guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw POSIXError(.EADDRNOTAVAIL) }

            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    connect(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connectResult != 0 {
                guard errno == EINPROGRESS else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
                var pollDescriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let pollResult = poll(&pollDescriptor, 1, Int32(timeoutSeconds * 1000))
                guard pollResult > 0 else { throw pollResult == 0 ? POSIXError(.ETIMEDOUT) : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fileDescriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: socketError) ?? .ECONNREFUSED)
                }
            }
            if blocking { try setBlocking(fileDescriptor) }
            return fileDescriptor
        } catch {
            close(fileDescriptor)
            throw error
        }
    }

    private static func setNonBlocking(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func setBlocking(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }
}

/// Writes `data` to `fileDescriptor` in full, retrying short writes and `EINTR`. Returns `false` on any
/// unrecoverable write error so the caller can tear the tunnel down. Used for blocking writes on a
/// dedicated relay queue, never on the server queue.
func spacesDeviceServiceTunnelWriteAll(fileDescriptor: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { rawBuffer -> Bool in
        guard let baseAddress = rawBuffer.baseAddress else { return true }
        var remaining = rawBuffer.count
        var offset = 0
        while remaining > 0 {
            let written = write(fileDescriptor, baseAddress.advanced(by: offset), remaining)
            if written > 0 {
                remaining -= written
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            return false
        }
        return true
    }
}

enum SpacesDeviceServiceTunnelSSLReadiness {
    case read
    case write
}

enum SpacesDeviceServiceTunnelSSLPendingOperation: Equatable {
    enum Operation: Equatable {
        case read
        case write
    }

    case read(waitingFor: SpacesDeviceServiceTunnelSSLReadiness)
    case write(waitingFor: SpacesDeviceServiceTunnelSSLReadiness)

    var operation: Operation {
        switch self {
        case .read: return .read
        case .write: return .write
        }
    }

    var waitsForRead: Bool {
        switch self {
        case .read(waitingFor: .read), .write(waitingFor: .read): return true
        case .read(waitingFor: .write), .write(waitingFor: .write): return false
        }
    }

    var waitsForWrite: Bool {
        switch self {
        case .read(waitingFor: .write), .write(waitingFor: .write): return true
        case .read(waitingFor: .read), .write(waitingFor: .read): return false
        }
    }

    func isReady(clientReadable: Bool, clientWritable: Bool) -> Bool { waitsForRead ? clientReadable : clientWritable }
}

struct SpacesDeviceServiceTunnelClientSocketReadiness: Equatable {
    let readable: Bool
    let writable: Bool
}

func spacesDeviceServiceTunnelClientSocketReadiness(revents: Int16) -> SpacesDeviceServiceTunnelClientSocketReadiness {
    let terminalEvent = (revents & Int16(POLLHUP | POLLERR)) != 0
    return SpacesDeviceServiceTunnelClientSocketReadiness(
        readable: terminalEvent || (revents & Int16(POLLIN)) != 0, writable: terminalEvent || (revents & Int16(POLLOUT)) != 0)
}

#if canImport(Network) && canImport(Security)
    /// One live service tunnel on the Darwin (Network.framework) transport. The service→phone direction
    /// reads the loopback socket through `relaySource` and forwards each chunk over `connection`; the
    /// phone→service direction runs a `connection.receive` loop that blocking-writes to the loopback
    /// socket on `relayQueue`. All fd, source, and queue work is confined to `relayQueue`; the half-close
    /// and teardown flags are mutated only on the server queue.
    final class SpacesDeviceServiceTunnelRelay: @unchecked Sendable {
        let workspaceID: String
        let serviceName: String
        let installationID: String
        let loopbackFD: Int32
        let relayQueue: DispatchQueue
        let relaySource: DispatchSourceRead
        let connection: NWConnection

        private let lock = NSLock()
        private var relaySourceActivated = false
        private var backpressureSuspended = false
        private var tornDown = false

        /// True once the service closed its write side (loopback read EOF) and the phone was told the
        /// stream is complete. Server-queue only.
        var loopbackReadClosed = false
        /// True once the phone half-closed its write side and the loopback write side was shut down.
        /// Server-queue only.
        var phoneReceiveClosed = false

        init(
            workspaceID: String, serviceName: String, installationID: String, loopbackFD: Int32, relayQueue: DispatchQueue,
            relaySource: DispatchSourceRead, connection: NWConnection
        ) {
            self.workspaceID = workspaceID
            self.serviceName = serviceName
            self.installationID = installationID
            self.loopbackFD = loopbackFD
            self.relayQueue = relayQueue
            self.relaySource = relaySource
            self.connection = connection
        }

        var isTornDown: Bool {
            lock.lock()
            defer { lock.unlock() }
            return tornDown
        }

        /// Adds one backpressure suspend on top of the source's base activation while a phone send is in
        /// flight, so no further loopback data is read until the phone acknowledges the current chunk.
        func suspendForBackpressure() {
            lock.lock()
            defer { lock.unlock() }
            guard !tornDown, !backpressureSuspended else { return }
            backpressureSuspended = true
            relaySource.suspend()
        }

        func resumeAfterSend() {
            lock.lock()
            defer { lock.unlock() }
            guard !tornDown, backpressureSuspended else { return }
            backpressureSuspended = false
            relaySource.resume()
        }

        /// Performs the source's base activation once the tunnel open response has been delivered.
        /// Returns false if teardown won the setup race before activation.
        @discardableResult func activateRelaySource() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !tornDown, !relaySourceActivated else { return false }
            relaySourceActivated = true
            relaySource.resume()
            return true
        }

        /// Balances the source's base activation plus any outstanding backpressure suspend and marks
        /// the relay torn down so its event
        /// handler no-ops, letting `relaySource.cancel()` reach its cancel handler (which closes the fd).
        func prepareForCancel() {
            lock.lock()
            defer { lock.unlock() }
            guard !tornDown else { return }
            tornDown = true
            if backpressureSuspended {
                backpressureSuspended = false
                relaySource.resume()
            }
            if !relaySourceActivated {
                relaySourceActivated = true
                relaySource.resume()
            }
        }
    }

    extension SpacesDeviceAPIServer {
        /// Handles an `openServiceTunnel` request on the request connection's server queue: resolves and
        /// dials the service before replying, then converts the connection into a raw bidirectional byte
        /// pipe. Any residual bytes already buffered after the request line are written to the service
        /// first so a client that (incorrectly) pipelines does not lose data.
        func handleTunnelRequest(_ request: SpacesDeviceAPIRequest, connection: NWConnection, residual: Data) throws {
            guard case .openServiceTunnel(let tunnelRequest) = request.command else {
                sendTunnelResponseAndCancel(
                    SpacesDeviceAPIResponse(ok: false, message: "Tunnel requests must use the tunnel path.", errorCode: .misroutedRequest),
                    to: connection)
                return
            }
            guard let installationID = request.clientApp?.installationID.trimmingCharacters(in: .whitespacesAndNewlines), !installationID.isEmpty
            else {
                sendTunnelResponseAndCancel(
                    SpacesDeviceAPIResponse(ok: false, message: "Missing client installation ID.", errorCode: .invalidArgument), to: connection)
                return
            }
            guard tunnelRelays.count < Self.maxConcurrentServiceTunnels else {
                sendTunnelResponseAndCancel(
                    SpacesDeviceAPIResponse(ok: false, message: "Too many concurrent service tunnels.", errorCode: .busy), to: connection)
                return
            }

            switch try SpacesDeviceServiceTunnelResolver.resolve(tunnelRequest) {
            case .failure(let message, let errorCode):
                sendTunnelResponseAndCancel(SpacesDeviceAPIResponse(ok: false, message: message, errorCode: errorCode), to: connection)
                return
            case .port(let port):
                let loopbackFD: Int32
                do { loopbackFD = try SpacesDeviceServiceTunnelDialer.dialLoopback(port: port) } catch {
                    trace("tunnel_dial_failed service=\(tunnelRequest.serviceName) port=\(port) error=\(error)")
                    sendTunnelResponseAndCancel(
                        SpacesDeviceAPIResponse(
                            ok: false, message: "Service '\(tunnelRequest.serviceName)' is not accepting connections.", errorCode: .serviceNotRunning),
                        to: connection)
                    return
                }
                openTunnelRelay(
                    tunnelRequest: tunnelRequest, installationID: installationID, loopbackFD: loopbackFD, connection: connection, residual: residual)
            }
        }

        private func openTunnelRelay(
            tunnelRequest: SpacesDeviceServiceTunnelRequest, installationID: String, loopbackFD: Int32, connection: NWConnection, residual: Data
        ) {
            let relayQueue = DispatchQueue(label: "spaces.device.api.tunnel.\(installationID).\(ObjectIdentifier(connection))")
            let relaySource = DispatchSource.makeReadSource(fileDescriptor: loopbackFD, queue: relayQueue)
            let relay = SpacesDeviceServiceTunnelRelay(
                workspaceID: tunnelRequest.workspaceID, serviceName: tunnelRequest.serviceName, installationID: installationID,
                loopbackFD: loopbackFD, relayQueue: relayQueue, relaySource: relaySource, connection: connection)
            relaySource.setEventHandler { [weak self, weak relay] in
                guard let self, let relay, !relay.isTornDown else { return }
                self.forwardLoopbackData(relay)
            }
            relaySource.setCancelHandler { close(loopbackFD) }
            tunnelRelays[ObjectIdentifier(connection)] = relay

            // The single ok line is sent directly, bypassing networkShaper: once it is delivered the
            // connection is an opaque byte pipe, so shaping (chunking/pacing) must not touch it.
            sendTunnelResponseLine(SpacesDeviceAPIResponse(ok: true, message: "Tunnel open."), to: connection) { [weak self, weak relay] error in
                guard let self, let relay else { return }
                if let error {
                    self.trace("tunnel_open_send_error error=\(error)")
                    self.teardownTunnel(connection: relay.connection)
                    return
                }
                // Base activation of the service→phone source; backpressure suspend/resume rides on top.
                guard relay.activateRelaySource() else { return }
                self.startPhoneToServiceRelay(relay, residual: residual)
            }
        }

        /// Service→phone: reads one chunk from the loopback socket and forwards it, suspending the source
        /// until the phone acknowledges the send so a slow phone cannot make the daemon buffer unboundedly.
        private func forwardLoopbackData(_ relay: SpacesDeviceServiceTunnelRelay) {
            var buffer = [UInt8](repeating: 0, count: Self.serviceTunnelBufferSize)
            let count = read(relay.loopbackFD, &buffer, buffer.count)
            if count > 0 {
                let data = Data(bytes: buffer, count: count)
                relay.suspendForBackpressure()
                // Raw byte pipe: send directly, not through networkShaper, so tunnel bytes are delivered
                // verbatim without Device API stream shaping.
                relay.connection.send(
                    content: data, contentContext: .defaultMessage, isComplete: false,
                    completion: .contentProcessed { [weak self, weak relay] error in
                        guard let self, let relay else { return }
                        if let error {
                            self.trace("tunnel_forward_send_error error=\(error)")
                            self.teardownTunnel(connection: relay.connection)
                            return
                        }
                        relay.resumeAfterSend()
                    })
            } else if count == 0 {
                queue.async { [weak self, weak relay] in
                    guard let self, let relay else { return }
                    self.handleLoopbackReadClosed(relay)
                }
            } else {
                if errno == EINTR {
                    forwardLoopbackData(relay)
                    return
                }
                if errno == EWOULDBLOCK || errno == EAGAIN { return }
                queue.async { [weak self, weak relay] in
                    guard let self, let relay else { return }
                    self.teardownTunnel(connection: relay.connection)
                }
            }
        }

        /// Phone→service: writes each received chunk to the loopback socket on the relay queue (blocking
        /// writes stay off the server queue), issuing the next receive only after the write drains so the
        /// phone is paced by how fast the service consumes.
        private func startPhoneToServiceRelay(_ relay: SpacesDeviceServiceTunnelRelay, residual: Data) {
            guard !residual.isEmpty else {
                receiveFromPhone(relay)
                return
            }
            relay.relayQueue.async { [weak self, weak relay] in
                guard let self, let relay else { return }
                guard spacesDeviceServiceTunnelWriteAll(fileDescriptor: relay.loopbackFD, data: residual) else {
                    self.queue.async { [weak self, weak relay] in
                        guard let self, let relay else { return }
                        self.teardownTunnel(connection: relay.connection)
                    }
                    return
                }
                self.receiveFromPhone(relay)
            }
        }

        private func receiveFromPhone(_ relay: SpacesDeviceServiceTunnelRelay) {
            relay.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.serviceTunnelBufferSize) {
                [weak self, weak relay] content, _, isComplete, error in
                guard let self, let relay else { return }
                if let error {
                    self.trace("tunnel_receive_error error=\(error)")
                    self.teardownTunnel(connection: relay.connection)
                    return
                }
                if let content, !content.isEmpty {
                    relay.relayQueue.async { [weak self, weak relay] in
                        guard let self, let relay else { return }
                        guard spacesDeviceServiceTunnelWriteAll(fileDescriptor: relay.loopbackFD, data: content) else {
                            self.queue.async { [weak self, weak relay] in
                                guard let self, let relay else { return }
                                self.teardownTunnel(connection: relay.connection)
                            }
                            return
                        }
                        if isComplete {
                            self.queue.async { [weak self, weak relay] in
                                guard let self, let relay else { return }
                                self.handlePhoneReceiveClosed(relay)
                            }
                        } else {
                            self.receiveFromPhone(relay)
                        }
                    }
                } else if isComplete {
                    self.handlePhoneReceiveClosed(relay)
                } else {
                    self.receiveFromPhone(relay)
                }
            }
        }

        /// Service closed its write side (loopback read EOF): flush the already-sequenced echo data
        /// (each forwarded chunk is acknowledged before the next loopback read), send the final close,
        /// and tear the tunnel down once that close is flushed. Network.framework TLS cannot express a
        /// half-close — a `.finalMessage` send alone is never surfaced to the peer's pending receive,
        /// and only `cancel()` emits the close_notify the phone observes as a clean EOF — so service
        /// EOF ends the whole tunnel here instead of leaving the phone→service direction open.
        private func handleLoopbackReadClosed(_ relay: SpacesDeviceServiceTunnelRelay) {
            guard !relay.loopbackReadClosed else { return }
            relay.loopbackReadClosed = true
            relay.suspendForBackpressure()
            relay.connection.send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { [weak self, weak relay] _ in
                    guard let self, let relay else { return }
                    // Teardown is deferred to the completion so cancel() (which flushes the clean
                    // close_notify) happens after all forwarded bytes were handed to the transport.
                    self.performOnQueue { self.teardownTunnel(connection: relay.connection) }
                })
        }

        /// Phone closed its write side (a clean `cancel()` from the phone surfaces here as
        /// `isComplete`): shut down the loopback write side on the relay queue — serialized after any
        /// pending phone-byte writes so nothing is dropped — and keep relaying fd→phone until the
        /// service side also finishes.
        private func handlePhoneReceiveClosed(_ relay: SpacesDeviceServiceTunnelRelay) {
            guard !relay.phoneReceiveClosed else { return }
            relay.phoneReceiveClosed = true
            let loopbackFD = relay.loopbackFD
            relay.relayQueue.async { shutdown(loopbackFD, SHUT_WR) }
        }

        /// Tears a tunnel down exactly once: cancels the loopback source (its cancel handler closes the
        /// fd), unblocks any in-flight blocking write via `shutdown`, and cancels the phone connection.
        /// Idempotent and safe to call from any teardown hook, all of which run on the server queue.
        func teardownTunnel(connection: NWConnection, cancelConnection: Bool = true) {
            guard let relay = tunnelRelays.removeValue(forKey: ObjectIdentifier(connection)) else { return }
            trace("tunnel_close peer=\(String(describing: connection.endpoint))")
            relay.prepareForCancel()
            relay.relaySource.cancel()
            shutdown(relay.loopbackFD, SHUT_RDWR)
            if cancelConnection { connection.cancel() }
        }

        private func sendTunnelResponseLine(
            _ response: SpacesDeviceAPIResponse, to connection: NWConnection, completion: @escaping @Sendable (Error?) -> Void
        ) {
            do {
                let data = try SpacesDeviceAPICodec.encodeResponseLine(response)
                connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed(completion))
            } catch { completion(error) }
        }

        private func sendTunnelResponseAndCancel(_ response: SpacesDeviceAPIResponse, to connection: NWConnection) {
            sendTunnelResponseLine(response, to: connection) { _ in connection.cancel() }
        }

        func teardownTunnels(forInstallationID installationID: String) {
            let connections = tunnelRelays.values.filter { $0.installationID == installationID }.map(\.connection)
            for connection in connections { teardownTunnel(connection: connection) }
        }

        func teardownAllTunnels() { for relay in Array(tunnelRelays.values) { teardownTunnel(connection: relay.connection) } }
    }
#endif

#if os(Linux) && canImport(OpenSSL)
    /// Splices a client TLS connection to a workspace service over the loopback socket with a single
    /// `poll(2)` loop. One `SSL*` is never read and written from two threads (it is not thread-safe), so
    /// both directions are driven from one loop with bounded in-memory buffers and poll-derived readiness.
    enum SpacesDeviceServiceTunnelSplicer {
        private static let bufferCapacity = SpacesDeviceAPIServer.serviceTunnelBufferSize

        /// - Parameter residual: bytes already read past the request line's newline (a pipelining
        ///   client's first tunnel bytes); they are written to the service before any new client reads.
        static func splice(ssl: OpaquePointer, clientFD: Int32, loopbackFD: Int32, residual: Data = Data()) throws {
            _ = spaces_SSL_set_partial_write_mode(ssl)
            try setNonBlocking(clientFD)

            var toService = [UInt8](residual)  // bytes read from the client (TLS), pending write to the service
            var toClient = [UInt8]()  // bytes read from the service, pending write to the client (TLS)
            toService.reserveCapacity(bufferCapacity)
            toClient.reserveCapacity(bufferCapacity)

            var clientReadClosed = false  // client sent close_notify
            var loopbackReadClosed = false  // service closed its write side (EOF)
            var loopbackWriteShutdown = false
            var sslShutdownSent = false

            // OpenSSL requires retrying the same SSL_read/SSL_write operation after WANT_READ/WANT_WRITE,
            // even when the operation wants the opposite socket readiness.
            var pendingSSLRetry: SpacesDeviceServiceTunnelSSLPendingOperation?

            var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

            while true {
                if clientReadClosed, loopbackReadClosed, toService.isEmpty, toClient.isEmpty { break }

                let canReadFromClient = !clientReadClosed && toService.count < bufferCapacity
                let canReadFromLoopback = !loopbackReadClosed && toClient.count < bufferCapacity && pendingSSLRetry?.operation != .write

                var clientEvents: Int16 = 0
                if let pendingSSLRetry {
                    if pendingSSLRetry.waitsForRead { clientEvents |= Int16(POLLIN) }
                    if pendingSSLRetry.waitsForWrite { clientEvents |= Int16(POLLOUT) }
                } else {
                    if canReadFromClient { clientEvents |= Int16(POLLIN) }
                    if !toClient.isEmpty { clientEvents |= Int16(POLLOUT) }
                }
                var loopbackEvents: Int16 = 0
                if canReadFromLoopback { loopbackEvents |= Int16(POLLIN) }
                if !toService.isEmpty { loopbackEvents |= Int16(POLLOUT) }

                if clientEvents == 0, loopbackEvents == 0 { break }

                var descriptors = [
                    pollfd(fd: clientFD, events: clientEvents, revents: 0), pollfd(fd: loopbackFD, events: loopbackEvents, revents: 0),
                ]
                let pollResult = poll(&descriptors, 2, -1)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }

                let clientReadiness = spacesDeviceServiceTunnelClientSocketReadiness(revents: descriptors[0].revents)
                let clientReadable = clientReadiness.readable
                let clientWritable = clientReadiness.writable
                let loopbackReadable = (descriptors[1].revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0
                let loopbackWritable = (descriptors[1].revents & Int16(POLLOUT)) != 0

                // 1. Client (TLS) → toService.
                let shouldReadClient: Bool
                if let pendingSSLRetry {
                    shouldReadClient =
                        pendingSSLRetry.operation == .read && pendingSSLRetry.isReady(clientReadable: clientReadable, clientWritable: clientWritable)
                } else {
                    shouldReadClient = clientReadable
                }
                if canReadFromClient, shouldReadClient {
                    let want = min(bufferCapacity - toService.count, readBuffer.count)
                    let readCount = SSL_read(ssl, &readBuffer, Int32(want))
                    if readCount > 0 {
                        pendingSSLRetry = nil
                        toService.append(contentsOf: readBuffer[0..<Int(readCount)])
                    } else {
                        switch SSL_get_error(ssl, readCount) {
                        case SSL_ERROR_ZERO_RETURN:
                            pendingSSLRetry = nil
                            clientReadClosed = true
                        case SSL_ERROR_WANT_READ: pendingSSLRetry = .read(waitingFor: .read)
                        case SSL_ERROR_WANT_WRITE: pendingSSLRetry = .read(waitingFor: .write)
                        default: throw POSIXError(.EIO)
                        }
                    }
                }

                // 2. toService → service.
                if !toService.isEmpty, loopbackWritable {
                    let written = toService.withUnsafeBytes { rawBuffer in write(loopbackFD, rawBuffer.baseAddress, toService.count) }
                    if written > 0 {
                        toService.removeFirst(written)
                    } else if written < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }

                // 2b. Client done and its bytes flushed: half-close the service write side once.
                if clientReadClosed, toService.isEmpty, !loopbackWriteShutdown {
                    shutdown(loopbackFD, Int32(SHUT_WR))
                    loopbackWriteShutdown = true
                }

                // 3. Service → toClient.
                if !loopbackReadClosed, toClient.count < bufferCapacity, loopbackReadable {
                    let want = min(bufferCapacity - toClient.count, readBuffer.count)
                    let readCount = read(loopbackFD, &readBuffer, want)
                    if readCount > 0 {
                        toClient.append(contentsOf: readBuffer[0..<readCount])
                    } else if readCount == 0 {
                        loopbackReadClosed = true
                    } else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }

                // 4. toClient → client (TLS).
                let shouldWriteClient: Bool
                if let pendingSSLRetry {
                    shouldWriteClient =
                        pendingSSLRetry.operation == .write && pendingSSLRetry.isReady(clientReadable: clientReadable, clientWritable: clientWritable)
                } else {
                    shouldWriteClient = clientWritable
                }
                if !toClient.isEmpty, shouldWriteClient {
                    let writeCount = toClient.withUnsafeBytes { rawBuffer in
                        SSL_write(ssl, rawBuffer.baseAddress, Int32(min(toClient.count, Int(Int32.max))))
                    }
                    if writeCount > 0 {
                        pendingSSLRetry = nil
                        toClient.removeFirst(Int(writeCount))
                    } else {
                        switch SSL_get_error(ssl, writeCount) {
                        case SSL_ERROR_WANT_READ: pendingSSLRetry = .write(waitingFor: .read)
                        case SSL_ERROR_WANT_WRITE: pendingSSLRetry = .write(waitingFor: .write)
                        default: throw POSIXError(.EIO)
                        }
                    }
                }

                // 4b. Service done and its bytes flushed to the client: send our close_notify once.
                // Continued SSL_read is still allowed so the client's own close_notify is observed.
                if loopbackReadClosed, toClient.isEmpty, !sslShutdownSent {
                    _ = SSL_shutdown(ssl)
                    sslShutdownSent = true
                }
            }
        }

        private static func setNonBlocking(_ fileDescriptor: Int32) throws {
            let flags = fcntl(fileDescriptor, F_GETFL)
            guard flags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
#endif
