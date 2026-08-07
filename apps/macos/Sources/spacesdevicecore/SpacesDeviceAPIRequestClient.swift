import Foundation
import spacesterminalcore

public enum SpacesDeviceAPIRequestClientError: LocalizedError {
    case invalidPort
    case emptyResponse
    case connectionFailed(String)
    case timeout(String)
    /// A reachable daemon answered with a coded rejection rather than failing to connect. Carries the
    /// daemon's `errorCode` so callers can branch on the category (e.g. re-authenticate on
    /// `.unauthorized`) instead of collapsing the rejection into an opaque `.connectionFailed`, which
    /// would look like a reachability failure and drop the code.
    case requestRejected(message: String, code: SpacesDeviceErrorCode?)

    public var errorDescription: String? {
        switch self {
        case .invalidPort: "The Device API port is invalid."
        case .emptyResponse: "The Device API connection closed before returning a response."
        case .connectionFailed(let message): message
        case .timeout(let message): message
        case .requestRejected(let message, _): message
        }
    }
}

/// One-shot Device API request client: opens a pinned-TLS connection per request, through the
/// device's endpoint resolver so every request races the device's candidate addresses and lands on
/// whichever one currently answers. All Device API clients authenticate the daemon by pinning its TLS
/// identity fingerprint recorded at pairing time; authorization is the bearer token inside the request
/// payload.
public final class SpacesDeviceAPIRequestClient: @unchecked Sendable {
    private let resolver: SpacesDeviceEndpointResolver
    private let timeoutSeconds: TimeInterval

    public init(resolver: SpacesDeviceEndpointResolver, timeoutSeconds: TimeInterval = 10) throws {
        guard UInt16(exactly: resolver.port) != nil, resolver.port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.resolver = resolver
        self.timeoutSeconds = timeoutSeconds
    }

    public func request(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
        try SpacesDeviceAPICodec.decodeResponse(requestData(SpacesDeviceAPICodec.encodeRequest(request)))
    }

    public func requestData(_ requestData: Data) throws -> Data {
        let resolved = try resolver.connect(timeout: timeoutSeconds)
        defer { resolved.connection.cancel() }
        do {
            try resolved.connection.sendLine(requestData, timeout: timeoutSeconds)
            do { return try resolved.connection.readLine(timeout: timeoutSeconds) } catch SpacesPinnedTLSConnectionError.connectionClosed {
                throw SpacesDeviceAPIRequestClientError.emptyResponse
            }
        } catch {
            // The address answered the handshake and then broke mid-exchange, so it may no longer be
            // the right one to go straight back to; the next connect re-walks every candidate.
            resolver.noteConnectionFailed(host: resolved.host)
            throw error
        }
    }
}

/// Persistent Device API request channel: keeps one pinned-TLS connection open across requests,
/// reconnecting when the daemon closes an idle socket. Requests marked safe to replay are retried
/// once on a fresh connection after a closed-connection failure.
public final class SpacesDeviceAPIRequestSessionClient: @unchecked Sendable {
    // The Linux Device API server closes idle request sockets after 120 seconds.
    // Reconnect before that so non-replayable terminal controls are written to a fresh socket.
    private static let defaultIdleReconnectInterval: TimeInterval = 90

    private let resolver: SpacesDeviceEndpointResolver
    private let idleReconnectInterval: TimeInterval
    private let uptime: @Sendable () -> TimeInterval
    private let requestLock = NSLock()
    private var connection: (any SpacesPinnedTLSLineConnection)?
    /// The candidate the open connection was resolved to, so a failure can be reported against the
    /// address that actually broke.
    private var connectionHost: String?
    private var lastConnectionUseUptime: TimeInterval?
    private var openedConnectionCount = 0

    public convenience init(resolver: SpacesDeviceEndpointResolver) throws {
        try self.init(resolver: resolver, idleReconnectInterval: Self.defaultIdleReconnectInterval, uptime: { ProcessInfo.processInfo.systemUptime })
    }

    init(resolver: SpacesDeviceEndpointResolver, idleReconnectInterval: TimeInterval, uptime: @escaping @Sendable () -> TimeInterval) throws {
        guard UInt16(exactly: resolver.port) != nil, resolver.port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.resolver = resolver
        self.idleReconnectInterval = idleReconnectInterval
        self.uptime = uptime
    }

    var openedConnectionCountForTesting: Int {
        requestLock.lock()
        let value = openedConnectionCount
        requestLock.unlock()
        return value
    }

    deinit { cancel() }

    public func cancel() {
        requestLock.lock()
        closeLocked()
        requestLock.unlock()
    }

    public func send(_ request: SpacesDeviceAPIRequest, timeoutSeconds: TimeInterval = 10) throws -> SpacesDeviceAPIResponse {
        requestLock.lock()
        defer { requestLock.unlock() }
        do { return try sendOnceLocked(request, timeoutSeconds: timeoutSeconds) } catch {
            guard request.isSafeToReplayAfterConnectionFailure, Self.isClosedConnectionError(error) else {
                closeAfterFailureLocked()
                throw error
            }
            closeAfterFailureLocked()
            do { return try sendOnceLocked(request, timeoutSeconds: timeoutSeconds) } catch {
                closeAfterFailureLocked()
                throw error
            }
        }
    }

    /// Reports the broken address to the resolver and drops the connection, so the replay (and every
    /// later request) resolves again instead of going straight back to an address that just failed.
    private func closeAfterFailureLocked() {
        if let connectionHost { resolver.noteConnectionFailed(host: connectionHost) }
        closeLocked()
    }

    private func sendOnceLocked(_ request: SpacesDeviceAPIRequest, timeoutSeconds: TimeInterval) throws -> SpacesDeviceAPIResponse {
        let activeConnection = try connectionLocked(timeoutSeconds: timeoutSeconds)
        try activeConnection.sendLine(try SpacesDeviceAPICodec.encodeRequest(request), timeout: timeoutSeconds)
        let line: Data
        do { line = try activeConnection.readLine(timeout: timeoutSeconds) } catch SpacesPinnedTLSConnectionError.connectionClosed {
            throw SpacesDeviceAPIRequestClientError.emptyResponse
        }
        let response = try SpacesDeviceAPICodec.decodeResponse(line)
        lastConnectionUseUptime = uptime()
        return response
    }

    private func connectionLocked(timeoutSeconds: TimeInterval) throws -> any SpacesPinnedTLSLineConnection {
        if let connection, !connectionIsIdleExpired() { return connection }
        closeLocked()
        let resolved = try resolver.connect(timeout: timeoutSeconds)
        connection = resolved.connection
        connectionHost = resolved.host
        lastConnectionUseUptime = uptime()
        openedConnectionCount += 1
        return resolved.connection
    }

    private func closeLocked() {
        connection?.cancel()
        connection = nil
        connectionHost = nil
        lastConnectionUseUptime = nil
    }

    private func connectionIsIdleExpired() -> Bool {
        guard let lastConnectionUseUptime else { return false }
        return uptime() - lastConnectionUseUptime >= idleReconnectInterval
    }

    private static func isClosedConnectionError(_ error: any Error) -> Bool {
        if case SpacesDeviceAPIRequestClientError.emptyResponse = error { return true }
        return SpacesPinnedTLSConnector.isClosedConnectionError(error)
    }

    static func debugIsClosedConnectionErrorForTesting(_ error: any Error) -> Bool { isClosedConnectionError(error) }
}

/// How the stream transports pick and invalidate a candidate address. Streams never race candidates —
/// a stream's connect is one blocking step inside a reconnect driver that already owns the retry
/// schedule — so each attempt takes the resolver's current preference and reports a failure back, and
/// the rotation happens across reconnect attempts (see `SpacesDeviceEndpointResolver.nextStreamHost`).
enum SpacesDeviceAPIStreamEndpoint {
    static func host(resolver: SpacesDeviceEndpointResolver) throws -> String {
        guard let host = resolver.nextStreamHost() else { throw SpacesDeviceEndpointResolverError.noCandidateHosts }
        return host
    }

    /// Wraps a disconnect handler so a stream that ended with an error reports the address it was on as
    /// failed, and the next reconnect moves on to a different candidate. A nil error is a deliberate
    /// teardown (the caller stopped the stream) and must not invalidate an address that never failed.
    static func invalidating(_ onDisconnect: @escaping @Sendable ((any Error)?) -> Void, resolver: SpacesDeviceEndpointResolver, host: String)
        -> @Sendable ((any Error)?) -> Void
    {
        { error in
            if error != nil { resolver.noteStreamFailed(host: host) }
            onDisconnect(error)
        }
    }
}

/// Reads a terminal-state subscription stream: opens a pinned-TLS Device API connection, sends
/// the subscribe request, and delivers each newline-framed state payload.
public final class SpacesDeviceAPIStateStreamClient: TerminalRemoteStateStreamClient, @unchecked Sendable {
    private let request: SpacesDeviceAPIRequest
    private let resolver: SpacesDeviceEndpointResolver
    private let onEvent: @Sendable (GhosttyRemoteSessionStatePayload) -> Void
    private let onDisconnect: @Sendable ((any Error)?) -> Void
    private let connectionLock = NSLock()
    private var connection: (any SpacesPinnedTLSLineConnection)?

    public init(
        request: SpacesDeviceAPIRequest, resolver: SpacesDeviceEndpointResolver,
        onEvent: @escaping @Sendable (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws {
        guard UInt16(exactly: resolver.port) != nil, resolver.port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.request = request
        self.resolver = resolver
        self.onEvent = onEvent
        self.onDisconnect = onDisconnect
    }

    /// The receive loop holds this client weakly, so dropping the last reference to a live stream
    /// leaves its pinned-TLS connection running until something cancels it. Cancelling here makes the
    /// reference-drop path safe by construction, matching `SpacesDeviceAPIRequestSessionClient`.
    deinit { stop() }

    public func start(timeoutSeconds: TimeInterval = 10) throws {
        let host = try SpacesDeviceAPIStreamEndpoint.host(resolver: resolver)
        let createdConnection: any SpacesPinnedTLSLineConnection
        do { createdConnection = try resolver.connect(host: host, timeout: timeoutSeconds) } catch {
            resolver.noteStreamFailed(host: host)
            throw error
        }
        connectionLock.lock()
        connection = createdConnection
        connectionLock.unlock()
        let onDisconnect = SpacesDeviceAPIStreamEndpoint.invalidating(onDisconnect, resolver: resolver, host: host)
        do { try createdConnection.sendLine(try SpacesDeviceAPICodec.encodeRequest(request), timeout: timeoutSeconds) } catch {
            resolver.noteStreamFailed(host: host)
            throw error
        }
        let onEvent = onEvent
        createdConnection.startReceiveLoop(
            onLine: { [weak self] line in
                do { onEvent(try GhosttyRemoteSessionStateCodec.decodeLine(line)) } catch {
                    onDisconnect(Self.streamDecodeError(for: line, fallback: error))
                    self?.stop()
                }
            }, onClosed: { error in onDisconnect(error) })
    }

    public func stop() {
        connectionLock.lock()
        let activeConnection = connection
        connection = nil
        connectionLock.unlock()
        activeConnection?.cancel()
    }

    private static func streamDecodeError(for line: Data, fallback: any Error) -> any Error {
        guard let response = try? SpacesDeviceAPICodec.decodeResponse(line) else { return fallback }
        // Preserve the daemon's error code: a subscribe the daemon rejects (notably `.unauthorized` for a
        // revoked token) arrives as a response line here, and the disconnect handler branches on the code
        // to decide whether to re-authenticate before reconnecting.
        return SpacesDeviceAPIRequestClientError.requestRejected(message: response.message, code: response.errorCode)
    }
}

/// Reads the device-overview subscription stream: opens a pinned-TLS Device API
/// connection, sends a `subscribeDeviceOverview` request, and delivers each
/// newline-framed overview payload. Mirrors `SpacesDeviceAPIStateStreamClient`
/// but decodes overview payloads instead of terminal state.
public final class SpacesDeviceAPIOverviewStreamClient: @unchecked Sendable {
    private let request: SpacesDeviceAPIRequest
    private let resolver: SpacesDeviceEndpointResolver
    private let onOverview: @Sendable (SpacesDeviceOverviewPayload) -> Void
    private let onDisconnect: @Sendable ((any Error)?) -> Void
    private let connectionLock = NSLock()
    private var connection: (any SpacesPinnedTLSLineConnection)?

    public init(
        authToken: String?, clientApp: SpacesDeviceClientApp?, resolver: SpacesDeviceEndpointResolver,
        onOverview: @escaping @Sendable (SpacesDeviceOverviewPayload) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws {
        guard UInt16(exactly: resolver.port) != nil, resolver.port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.request = SpacesDeviceAPIRequest(command: .subscribeDeviceOverview, authToken: authToken, clientApp: clientApp)
        self.resolver = resolver
        self.onOverview = onOverview
        self.onDisconnect = onDisconnect
    }

    /// The receive loop holds this client weakly, so dropping the last reference to a live stream
    /// leaves its pinned-TLS connection running until something cancels it. Cancelling here makes the
    /// reference-drop path safe by construction, matching `SpacesDeviceAPIRequestSessionClient`.
    deinit { stop() }

    public func start(timeoutSeconds: TimeInterval = 10) throws {
        let host = try SpacesDeviceAPIStreamEndpoint.host(resolver: resolver)
        let createdConnection: any SpacesPinnedTLSLineConnection
        do { createdConnection = try resolver.connect(host: host, timeout: timeoutSeconds) } catch {
            resolver.noteStreamFailed(host: host)
            throw error
        }
        connectionLock.lock()
        connection = createdConnection
        connectionLock.unlock()
        let onDisconnect = SpacesDeviceAPIStreamEndpoint.invalidating(onDisconnect, resolver: resolver, host: host)
        do { try createdConnection.sendLine(try SpacesDeviceAPICodec.encodeRequest(request), timeout: timeoutSeconds) } catch {
            resolver.noteStreamFailed(host: host)
            throw error
        }
        let onOverview = onOverview
        createdConnection.startReceiveLoop(
            onLine: { [weak self] line in
                do { onOverview(try SpacesDeviceOverviewStreamCodec.decodeLine(line)) } catch {
                    // A non-payload line is usually a server error response; surface its message.
                    if let response = try? SpacesDeviceAPICodec.decodeResponse(line) {
                        onDisconnect(SpacesDeviceAPIRequestClientError.connectionFailed(response.message))
                    } else {
                        onDisconnect(error)
                    }
                    self?.stop()
                }
            }, onClosed: { error in onDisconnect(error) })
    }

    public func stop() {
        connectionLock.lock()
        let activeConnection = connection
        connection = nil
        connectionLock.unlock()
        activeConnection?.cancel()
    }
}
