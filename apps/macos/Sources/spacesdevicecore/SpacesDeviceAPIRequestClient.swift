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

    /// Sends one request, racing the device's candidate addresses — unless `pinnedHost` names one, in
    /// which case the request goes to exactly that address and nowhere else. Pinning exists for a caller
    /// asking about one specific address rather than about the device: a client holding a long-lived
    /// stream on one candidate cannot learn anything about that candidate from a request the race happily
    /// answers on a different one.
    public func request(_ request: SpacesDeviceAPIRequest, pinnedHost: String? = nil) throws -> SpacesDeviceAPIResponse {
        try SpacesDeviceAPICodec.decodeResponse(requestData(SpacesDeviceAPICodec.encodeRequest(request), pinnedHost: pinnedHost))
    }

    public func requestData(_ requestData: Data) throws -> Data {
        try self.requestData(requestData, pinnedHost: nil)
    }

    private func requestData(_ requestData: Data, pinnedHost: String?) throws -> Data {
        let host: String
        let connection: any SpacesPinnedTLSLineConnection
        if let pinnedHost {
            host = pinnedHost
            do { connection = try resolver.connect(host: pinnedHost, timeout: timeoutSeconds) } catch {
                noteFailure(host: pinnedHost, isPinned: true)
                throw error
            }
        } else {
            let resolved = try resolver.connect(timeout: timeoutSeconds)
            host = resolved.host
            connection = resolved.connection
        }
        defer { connection.cancel() }
        do {
            try connection.sendLine(requestData, timeout: timeoutSeconds)
            do {
                return try connection.readLine(timeout: timeoutSeconds)
            } catch SpacesPinnedTLSConnectionError.connectionClosed {
                throw SpacesDeviceAPIRequestClientError.emptyResponse
            }
        } catch {
            noteFailure(host: host, isPinned: pinnedHost != nil)
            throw error
        }
    }

    /// A raced request that broke tells the resolver only that its winner is no longer the right address
    /// to go straight back to; the next connect re-walks every candidate. A pinned request that broke is
    /// evidence about that one address specifically, which is what a stream needs: reporting it as a
    /// stream failure moves `nextStreamHost()` off the address instead of redialing it first.
    private func noteFailure(host: String, isPinned: Bool) {
        if isPinned {
            resolver.noteStreamFailed(host: host)
        } else {
            resolver.noteConnectionFailed(host: host)
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

    /// Wraps a disconnect handler so a stream that ended because its *address* failed reports that
    /// address as failed, and the next reconnect moves on to a different candidate.
    static func invalidating(_ onDisconnect: @escaping @Sendable ((any Error)?) -> Void, resolver: SpacesDeviceEndpointResolver, host: String)
        -> @Sendable ((any Error)?) -> Void
    {
        { error in
            if isHostTransportFailure(error) { resolver.noteStreamFailed(host: host) }
            onDisconnect(error)
        }
    }

    /// Whether a stream's ending is evidence against the address it was on.
    ///
    /// "The stream ended" and "this address is bad" are different facts, and only the second may rotate
    /// the stream off a candidate or drop the shared cached winner. Getting this wrong is expensive in
    /// both directions: marking a good address failed sends every later reconnect to a worse candidate
    /// and can walk a working device off the address it should be on, while missing a real failure keeps
    /// the stream retrying an address that is gone.
    ///
    /// Not a failure of the address:
    /// - `requestRejected` — the pinned handshake completed and the daemon answered on this very
    ///   connection, choosing to refuse the subscription (a revoked token, an ended session). The address
    ///   is demonstrably reachable and correct; the caller branches on the code to recover.
    /// - a decode failure — again delivered over a healthy connection, and evidence about a payload
    ///   rather than about a path.
    /// - a nil error. `SpacesPinnedTLSConnection`'s receive loop reports nil for two different endings,
    ///   and neither indicts the address: a clean peer EOF (`isComplete`, the daemon chose to close), and
    ///   a local teardown, where the loop sees its connection already cleared by `cancel()` and
    ///   deliberately reports nil rather than the cancellation error. That is what keeps `stop()` from
    ///   ever reporting a failure here.
    static func isHostTransportFailure(_ error: (any Error)?) -> Bool {
        guard let error else { return false }
        if let requestError = error as? SpacesDeviceAPIRequestClientError {
            switch requestError {
            case .timeout, .emptyResponse, .connectionFailed: return true
            case .invalidPort, .requestRejected: return false
            }
        }
        if let pinnedTLSError = error as? SpacesPinnedTLSConnectionError {
            switch pinnedTLSError {
            case .timeout, .connectionFailed, .connectionClosed: return true
            // Neither is about the path: an invalid port never reached one, and a second receive loop on
            // one connection is a programming error.
            case .invalidPort, .receiveLoopActive: return false
            }
        }
        // The raw drop shapes the transport surfaces without wrapping (reset, aborted, broken pipe), read
        // through the same authority the request path replays idempotent requests on.
        return SpacesPinnedTLSConnector.isClosedConnectionError(error)
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
    private var connectedHostStorage: String?

    /// The candidate address this stream is pinned to, once `start()` has connected; nil before that and
    /// after `stop()`. A stream picks its host once and keeps it for the life of the connection, so an
    /// owner comparing it against the address a fresh request just landed on can tell that the device
    /// failed over to a different candidate while this stream sat on a dead one.
    public var connectedHost: String? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return connectedHostStorage
    }

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
        connectedHostStorage = host
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
        connectedHostStorage = nil
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
                    // A non-payload line is usually a server error response; surface its message. Reported
                    // as a rejection rather than a connection failure because that is what it is: the
                    // daemon answered on a healthy connection, so this must not read as the address being
                    // unreachable — the message the user sees is the same either way.
                    if let response = try? SpacesDeviceAPICodec.decodeResponse(line) {
                        onDisconnect(SpacesDeviceAPIRequestClientError.requestRejected(message: response.message, code: response.errorCode))
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

/// Reads the per-(workspace, ref)-scope diff-signature subscription stream: opens a pinned-TLS Device API
/// connection, sends a `subscribeWorkspaceDiffSignature` request scoped to one workspace and optional ref,
/// and delivers each newline-framed `SpacesDeviceWorkspaceDiffSignatureFrame`. Mirrors
/// `SpacesDeviceAPIOverviewStreamClient`; the daemon pushes a frame when the scope's `scopeSignature`
/// changes (notify-then-pull) and, separately, an unconditional keepalive roughly every 20s whose
/// `scopeSignature` is unchanged (disconnect detection for a Linux relay blocked on a quiet producer — see
/// `SpacesDeviceWorkspaceDiffSignatureFrame`'s doc comment); this client drops that repeat before it
/// reaches `onFrame`, so a delivery here always means the owner should re-fetch `workspaceDiff`.
public final class SpacesDeviceWorkspaceDiffSignatureStreamClient: @unchecked Sendable {
    private let request: SpacesDeviceAPIRequest
    private let resolver: SpacesDeviceEndpointResolver
    private let onFrame: @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void
    private let onDisconnect: @Sendable ((any Error)?) -> Void
    private let connectionLock = NSLock()
    private var connection: (any SpacesPinnedTLSLineConnection)?
    /// Last signature delivered to `onFrame`, compared only from the receive loop's own callback (one
    /// connection, one serial stream of `onLine` calls), so it needs no lock.
    private var lastDeliveredSignature: String?

    public init(
        workspaceID: String, refName: String? = nil, authToken: String?, clientApp: SpacesDeviceClientApp?, resolver: SpacesDeviceEndpointResolver,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws {
        guard UInt16(exactly: resolver.port) != nil, resolver.port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.request = SpacesDeviceAPIRequest(
            command: .subscribeWorkspaceDiffSignature(SpacesDeviceWorkspaceDiffRequest(workspaceID: workspaceID, refName: refName)),
            authToken: authToken, clientApp: clientApp)
        self.resolver = resolver
        self.onFrame = onFrame
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
        let onFrame = onFrame
        createdConnection.startReceiveLoop(
            onLine: { [weak self] line in
                do {
                    let frame = try SpacesDeviceWorkspaceDiffSignatureStreamCodec.decodeLine(line)
                    guard let self else { return }
                    guard frame.scopeSignature != self.lastDeliveredSignature else { return }
                    self.lastDeliveredSignature = frame.scopeSignature
                    onFrame(frame)
                } catch {
                    // A non-payload line is usually a server error response; surface its message. Reported
                    // as a rejection rather than a connection failure because that is what it is: the
                    // daemon answered on a healthy connection, so this must not read as the address being
                    // unreachable — the message the user sees is the same either way.
                    if let response = try? SpacesDeviceAPICodec.decodeResponse(line) {
                        onDisconnect(SpacesDeviceAPIRequestClientError.requestRejected(message: response.message, code: response.errorCode))
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

/// Reads the per-(workspace, path)-scope file-signature subscription stream: opens a pinned-TLS Device
/// API connection, sends a `subscribeWorkspaceFileSignature` request scoped to one workspace-relative
/// file, and delivers each newline-framed `SpacesDeviceWorkspaceFileSignatureFrame`. Mirrors
/// `SpacesDeviceWorkspaceDiffSignatureStreamClient` exactly, substituting the whole-frame `Equatable`
/// comparison (`sha256`+`missing` together) for that client's single-field `scopeSignature` comparison,
/// since a file-signature frame has no equivalent single composite field to compare instead.
public final class SpacesDeviceWorkspaceFileSignatureStreamClient: @unchecked Sendable {
    private let request: SpacesDeviceAPIRequest
    private let resolver: SpacesDeviceEndpointResolver
    private let onFrame: @Sendable (SpacesDeviceWorkspaceFileSignatureFrame) -> Void
    private let onDisconnect: @Sendable ((any Error)?) -> Void
    private let connectionLock = NSLock()
    private var connection: (any SpacesPinnedTLSLineConnection)?
    /// Last frame delivered to `onFrame`, compared only from the receive loop's own callback (one
    /// connection, one serial stream of `onLine` calls), so it needs no lock.
    private var lastDeliveredFrame: SpacesDeviceWorkspaceFileSignatureFrame?

    public init(
        workspaceID: String, path: String, authToken: String?, clientApp: SpacesDeviceClientApp?, resolver: SpacesDeviceEndpointResolver,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceFileSignatureFrame) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws {
        guard UInt16(exactly: resolver.port) != nil, resolver.port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.request = SpacesDeviceAPIRequest(
            command: .subscribeWorkspaceFileSignature(SpacesDeviceWorkspaceFileSignatureRequest(workspaceID: workspaceID, path: path)),
            authToken: authToken, clientApp: clientApp)
        self.resolver = resolver
        self.onFrame = onFrame
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
        let onFrame = onFrame
        createdConnection.startReceiveLoop(
            onLine: { [weak self] line in
                do {
                    let frame = try SpacesDeviceWorkspaceFileSignatureStreamCodec.decodeLine(line)
                    guard let self else { return }
                    guard frame != self.lastDeliveredFrame else { return }
                    self.lastDeliveredFrame = frame
                    onFrame(frame)
                } catch {
                    // A non-payload line is usually a server error response; surface its message. Reported
                    // as a rejection rather than a connection failure because that is what it is: the
                    // daemon answered on a healthy connection, so this must not read as the address being
                    // unreachable — the message the user sees is the same either way.
                    if let response = try? SpacesDeviceAPICodec.decodeResponse(line) {
                        onDisconnect(SpacesDeviceAPIRequestClientError.requestRejected(message: response.message, code: response.errorCode))
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
