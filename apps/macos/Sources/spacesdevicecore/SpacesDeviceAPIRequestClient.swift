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
    /// A subscription connection stayed open but delivered no bytes for longer than
    /// `TerminalStreamLiveness.silenceTimeoutSeconds`. The daemon keepalives that rule this out for a
    /// healthy link make the silence conclusive: the transport is gone even though the socket is not.
    case streamStalled

    public var errorDescription: String? {
        switch self {
        case .invalidPort: "The Device API port is invalid."
        case .emptyResponse: "The Device API connection closed before returning a response."
        case .connectionFailed(let message): message
        case .timeout(let message): message
        case .requestRejected(let message, _): message
        case .streamStalled: "The terminal stream stopped responding."
        }
    }
}

/// Single-request Device API client: sends one request through the device's endpoint resolver, so it
/// races the device's candidate addresses and lands on whichever one currently answers. All Device API
/// clients authenticate the daemon by pinning its TLS identity fingerprint recorded at pairing time;
/// authorization is the bearer token inside the request payload.
///
/// The connection it sends on is not one-shot. A raced request takes the endpoint's warm connection
/// when one is parked and parks the connection back once the daemon has answered on it
/// (`SpacesDeviceAPIWarmConnectionStore`), so a command path issuing requests continuously — the
/// sidebar's overview read on every reload — pays one handshake and one certificate trust evaluation
/// for the endpoint rather than one per request.
public final class SpacesDeviceAPIRequestClient: @unchecked Sendable {
    private let resolver: SpacesDeviceEndpointResolver
    private let timeoutSeconds: TimeInterval
    private let warmConnections: SpacesDeviceAPIWarmConnectionStore
    private let endpointKey: String

    public convenience init(resolver: SpacesDeviceEndpointResolver, timeoutSeconds: TimeInterval = 10) throws {
        try self.init(resolver: resolver, timeoutSeconds: timeoutSeconds, warmConnections: .shared)
    }

    init(resolver: SpacesDeviceEndpointResolver, timeoutSeconds: TimeInterval, warmConnections: SpacesDeviceAPIWarmConnectionStore) throws {
        guard UInt16(exactly: resolver.port) != nil, resolver.port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.resolver = resolver
        self.timeoutSeconds = timeoutSeconds
        self.warmConnections = warmConnections
        endpointKey = SpacesDeviceAPIWarmConnectionStore.endpointKey(certificateFingerprint: resolver.certificateFingerprint, port: resolver.port)
    }

    /// Sends one request, racing the device's candidate addresses — unless `pinnedHost` names one, in
    /// which case the request goes to exactly that address and nowhere else. Pinning exists for a caller
    /// asking about one specific address rather than about the device: a client holding a long-lived
    /// stream on one candidate cannot learn anything about that candidate from a request the race happily
    /// answers on a different one.
    public func request(_ request: SpacesDeviceAPIRequest, pinnedHost: String? = nil) throws -> SpacesDeviceAPIResponse {
        let requestLine = try SpacesDeviceAPICodec.encodeRequest(request)
        guard let pinnedHost else { return try raced(requestLine, isSafeToReplay: request.isSafeToReplayAfterConnectionFailure) }
        return try pinned(requestLine, host: pinnedHost)
    }

    /// Time left until `deadline`, clamped so a stage that runs after an earlier one already spent the
    /// whole budget gets none, rather than a fresh `timeoutSeconds` of its own. Throws the same timeout
    /// error the pinned-TLS transport itself throws on an ordinary stage timeout, so a caller sees one
    /// failure shape regardless of which stage ran out.
    private func remainingOrTimeout(until deadline: Date) throws -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw SpacesPinnedTLSConnectionError.timeout }
        return remaining
    }

    /// A request aimed at one address. It always dials its own connection: the caller is asking whether
    /// *this* candidate answers right now, which a connection parked from a race — established on
    /// whichever candidate won then — cannot answer.
    ///
    /// This is the one-shot link-corroboration probe: it exists only to decide, within one budget,
    /// whether an address answers at all. So unlike `raced`, `timeoutSeconds` here is one end-to-end
    /// deadline for the whole call rather than a budget reissued to each stage: `deadline` is captured
    /// once at the top and every later stage (connect, send, read) is handed only what remains of it, so
    /// an address that accepts a dial and then never answers still fails around one `timeoutSeconds`, not
    /// the sum of however many stages the call happens to run.
    private func pinned(_ requestLine: Data, host: String) throws -> SpacesDeviceAPIResponse {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let connection: any SpacesPinnedTLSLineConnection
        do { connection = try resolver.connect(host: host, timeout: remainingOrTimeout(until: deadline)) } catch {
            resolver.noteStreamFailed(host: host)
            throw error
        }
        defer { connection.cancel() }
        let responseLine: Data
        // A pinned request that broke is evidence about that one address specifically, which is what a
        // stream needs: reporting it as a stream failure moves `nextStreamHost()` off the address
        // instead of redialing it first. Decoding sits outside this: an answer that did not decode came
        // back over a healthy connection, so it is evidence about a payload rather than about an address.
        do {
            try connection.sendLine(requestLine, timeout: remainingOrTimeout(until: deadline))
            do { responseLine = try connection.readLine(timeout: remainingOrTimeout(until: deadline)) } catch SpacesPinnedTLSConnectionError.connectionClosed {
                throw SpacesDeviceAPIRequestClientError.emptyResponse
            }
        } catch {
            resolver.noteStreamFailed(host: host)
            throw error
        }
        return try SpacesDeviceAPICodec.decodeResponse(responseLine)
    }

    /// A request aimed at the device rather than at an address: it goes on the endpoint's warm
    /// connection when one is parked, and on a freshly raced one otherwise.
    ///
    /// Only a request that is safe to replay may take a parked connection. The daemon can close a parked
    /// socket at any time (it closes one after answering a rejected request, and the Linux server closes
    /// an idle one), and a client cannot tell a connection closed before its request was read from one
    /// closed after — so a request that must not run twice dials its own connection instead of retrying
    /// into that ambiguity. Those are the user-initiated mutations, which are rare; the continuous
    /// traffic this exists for (overview, daemon status, ping, state) is all replay-safe.
    private func raced(_ requestLine: Data, isSafeToReplay: Bool) throws -> SpacesDeviceAPIResponse {
        let generation = warmConnections.currentGeneration
        if isSafeToReplay, let warm = warmConnections.take(endpoint: endpointKey) {
            var reusedResponseLine: Data?
            do { reusedResponseLine = try exchange(requestLine, on: warm.connection) } catch {
                warm.connection.cancel()
                // A raced request that broke tells the resolver only that its winner is no longer the
                // right address to go straight back to; the next connect re-walks every candidate.
                resolver.noteConnectionFailed(host: warm.host)
                // The parked connection was already gone, so this attempt never reached the daemon:
                // dialing a fresh one and sending again is what keeps reuse invisible to callers. Any
                // other failure is this attempt's own outcome and is reported as it is.
                guard SpacesDeviceAPIConnectionFailure.isClosed(error) else { throw error }
            }
            if let reusedResponseLine { return try settle(reusedResponseLine, connection: warm.connection, host: warm.host, generation: generation) }
        }
        let resolved = try resolver.connect(timeout: timeoutSeconds)
        let responseLine: Data
        do { responseLine = try exchange(requestLine, on: resolved.connection) } catch {
            resolved.connection.cancel()
            resolver.noteConnectionFailed(host: resolved.host)
            throw error
        }
        return try settle(responseLine, connection: resolved.connection, host: resolved.host, generation: generation)
    }

    /// One round trip on an established connection.
    private func exchange(_ requestLine: Data, on connection: any SpacesPinnedTLSLineConnection) throws -> Data {
        try connection.sendLine(requestLine, timeout: timeoutSeconds)
        do { return try connection.readLine(timeout: timeoutSeconds) } catch SpacesPinnedTLSConnectionError.connectionClosed {
            throw SpacesDeviceAPIRequestClientError.emptyResponse
        }
    }

    /// Decodes the daemon's answer and decides what becomes of the connection it arrived on: parked for
    /// the next request, or closed.
    ///
    /// Only an `ok` answer parks. The server closes a request connection after the response it composes
    /// for a rejected request, so parking one would hand the next request a socket that is already gone;
    /// an answer that did not decode says nothing about the connection's state either.
    private func settle(_ responseLine: Data, connection: any SpacesPinnedTLSLineConnection, host: String, generation: Int) throws
        -> SpacesDeviceAPIResponse
    {
        let response: SpacesDeviceAPIResponse
        do { response = try SpacesDeviceAPICodec.decodeResponse(responseLine) } catch {
            connection.cancel()
            throw error
        }
        guard response.ok else {
            connection.cancel()
            return response
        }
        warmConnections.park(connection, host: host, endpoint: endpointKey, generation: generation)
        return response
    }
}

/// Whether a failure means the connection it happened on is gone, so the request may be retried on a
/// fresh one. Shared by both request clients so "the socket was closed under us" means the same thing
/// on the warm single-request path and on a pane's persistent session.
enum SpacesDeviceAPIConnectionFailure {
    static func isClosed(_ error: any Error) -> Bool {
        if case SpacesDeviceAPIRequestClientError.emptyResponse = error { return true }
        return SpacesPinnedTLSConnector.isClosedConnectionError(error)
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

    private static func isClosedConnectionError(_ error: any Error) -> Bool { SpacesDeviceAPIConnectionFailure.isClosed(error) }

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
            // `streamStalled` belongs with the reachability failures: the daemon keepalives that a live
            // path would carry stopped arriving on this address, so the next reconnect should be free to
            // try a different candidate rather than settle back onto the one that went quiet.
            case .timeout, .emptyResponse, .connectionFailed, .streamStalled: return true
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
    /// How long this stream may receive no bytes at all before it reports itself stalled. Injected only so
    /// tests can compress the wait; production always uses `TerminalStreamLiveness.silenceTimeoutSeconds`.
    private let silenceTimeout: TimeInterval
    /// Uptime of the last bytes received from the daemon, keepalives included. Guarded by `connectionLock`.
    private var lastReceiveUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    /// Set by whichever termination path runs first, so the silence watchdog can neither report a stream
    /// that has already ended nor keep polling after it. Guarded by `connectionLock`.
    private var hasFinished = false

    /// The candidate address this stream is pinned to, once `start()` has connected; nil before that and
    /// after `stop()`. A stream picks its host once and keeps it for the life of the connection, so an
    /// owner comparing it against the address a fresh request just landed on can tell that the device
    /// failed over to a different candidate while this stream sat on a dead one.
    public var connectedHost: String? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return connectedHostStorage
    }

    /// Whether the failed dial in `start()` was, at the moment it was recorded, evidence that every one
    /// of this device's candidate addresses has now failed a stream dial
    /// (`SpacesDeviceEndpointResolver.noteStreamFailed(host:)`'s return value). The owning model reads
    /// this instead of separately querying the resolver's live failed-host set afterward: with one
    /// resolver shared per device across every pane's stream, another pane's `nextStreamHost()` call can
    /// land between this dial's failure and a later query and self-reset that set, which would silently
    /// swallow real "every candidate is down" evidence. This value is captured atomically with the
    /// recording, so it cannot be raced out from under the reader that way. False until `start()` fails;
    /// meaningless (and left false) when `start()` succeeds or has not run yet.
    public var lastDialExhaustedAllCandidates: Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return lastDialExhaustedAllCandidatesStorage
    }
    private var lastDialExhaustedAllCandidatesStorage = false

    public init(
        request: SpacesDeviceAPIRequest, resolver: SpacesDeviceEndpointResolver,
        silenceTimeout: TimeInterval = TerminalStreamLiveness.silenceTimeoutSeconds,
        onEvent: @escaping @Sendable (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws {
        guard UInt16(exactly: resolver.port) != nil, resolver.port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.request = request
        self.resolver = resolver
        self.silenceTimeout = silenceTimeout
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
            let exhausted = resolver.noteStreamFailed(host: host)
            connectionLock.lock()
            lastDialExhaustedAllCandidatesStorage = exhausted
            connectionLock.unlock()
            throw error
        }
        connectionLock.lock()
        connection = createdConnection
        connectedHostStorage = host
        lastReceiveUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        hasFinished = false
        connectionLock.unlock()
        let onDisconnect = SpacesDeviceAPIStreamEndpoint.invalidating(onDisconnect, resolver: resolver, host: host)
        do { try createdConnection.sendLine(try SpacesDeviceAPICodec.encodeRequest(request), timeout: timeoutSeconds) } catch {
            let exhausted = resolver.noteStreamFailed(host: host)
            connectionLock.lock()
            lastDialExhaustedAllCandidatesStorage = exhausted
            connectionLock.unlock()
            throw error
        }
        let onEvent = onEvent
        createdConnection.startReceiveLoop(
            onLine: { [weak self] line in
                do { onEvent(try GhosttyRemoteSessionStateCodec.decodeLine(line)) } catch {
                    guard self?.markFinished() ?? true else { return }
                    onDisconnect(Self.streamDecodeError(for: line, fallback: error))
                    self?.stop()
                }
            },
            // Keepalive lines never reach `onLine` (the transport drops empty lines), so liveness is
            // tracked here: any byte off the wire, frame or keepalive, is proof the link is alive.
            onBytesReceived: { [weak self] in self?.noteBytesReceived() },
            onClosed: { [weak self] error in
                guard self?.markFinished() ?? true else { return }
                onDisconnect(error)
            })
        startSilenceWatch(onDisconnect: onDisconnect)
    }

    private func noteBytesReceived() {
        connectionLock.lock()
        lastReceiveUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        connectionLock.unlock()
    }

    /// True for the caller that got to end this stream, false for every later one, so a stall, a decode
    /// failure, and the receive loop's own close cannot each report a disconnect for the same stream.
    private func markFinished() -> Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard !hasFinished else { return false }
        hasFinished = true
        return true
    }

    /// Watches for the silence a dead-but-open transport produces; see `TerminalStreamLiveness`.
    ///
    /// The watch lives on its own thread rather than a GCD timer: a global or private concurrent
    /// queue is non-overcommit, and when the kernel workqueue is saturated (issue #611: cooperative-pool
    /// threads parked in blocking waits) its blocks are never provisioned a thread, so a timer-based
    /// watchdog can sit unscheduled for longer than the timeout it is meant to enforce. One sleeping
    /// thread per open stream is the price of a check that always runs.
    private func startSilenceWatch(onDisconnect: @escaping @Sendable ((any Error)?) -> Void) {
        let checkInterval = TerminalStreamLiveness.silenceCheckIntervalSeconds(forTimeout: silenceTimeout)
        SpacesBlockingIOThread.spawn(name: "spaces.device.stream.liveness") { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: checkInterval)
                guard let self else { return }
                connectionLock.lock()
                let isRunning = !hasFinished && connection != nil
                let silentSeconds = Double(DispatchTime.now().uptimeNanoseconds &- lastReceiveUptimeNanoseconds) / 1_000_000_000
                connectionLock.unlock()
                guard isRunning else { return }
                guard silentSeconds >= silenceTimeout else { continue }
                guard markFinished() else { return }
                onDisconnect(SpacesDeviceAPIRequestClientError.streamStalled)
                stop()
                return
            }
        }
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
            },
            // These signature and overview producers broadcast on their own timers, so silence here is a
            // real stall the transport itself surfaces; only the terminal stream needs a liveness watch.
            onBytesReceived: {}, onClosed: { error in onDisconnect(error) })
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
/// reaches `onFrame`, so a delivery here always means the owner should re-fetch `workspaceDiffManifestChunk`.
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
        workspaceID: String, refName: String? = nil, lastCommit: Bool = false, authToken: String?, clientApp: SpacesDeviceClientApp?,
        resolver: SpacesDeviceEndpointResolver, onFrame: @escaping @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void,
        onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws {
        guard UInt16(exactly: resolver.port) != nil, resolver.port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.request = SpacesDeviceAPIRequest(
            command: .subscribeWorkspaceDiffSignature(
                SpacesDeviceWorkspaceDiffRequest(workspaceID: workspaceID, refName: refName, lastCommit: lastCommit)), authToken: authToken,
            clientApp: clientApp)
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
            },
            // These signature and overview producers broadcast on their own timers, so silence here is a
            // real stall the transport itself surfaces; only the terminal stream needs a liveness watch.
            onBytesReceived: {}, onClosed: { error in onDisconnect(error) })
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
            },
            // These signature and overview producers broadcast on their own timers, so silence here is a
            // real stall the transport itself surfaces; only the terminal stream needs a liveness watch.
            onBytesReceived: {}, onClosed: { error in onDisconnect(error) })
    }

    public func stop() {
        connectionLock.lock()
        let activeConnection = connection
        connection = nil
        connectionLock.unlock()
        activeConnection?.cancel()
    }
}

/// Reads the per-workspace file-list-signature subscription stream: opens a pinned-TLS Device API
/// connection, sends a `subscribeWorkspaceFileListSignature` request scoped to one workspace, and
/// delivers each newline-framed `SpacesDeviceWorkspaceFileListSignatureFrame`. Unlike the diff/file
/// stream clients this transport intentionally does not dedupe identical payloads client-side: the host
/// only acknowledges a signature after its follow-up `workspaceFileList` pull succeeds, so repeated
/// identical keepalives are the retry signal after a transient pull failure.
public final class SpacesDeviceWorkspaceFileListSignatureStreamClient: @unchecked Sendable {
    private let request: SpacesDeviceAPIRequest
    private let resolver: SpacesDeviceEndpointResolver
    private let onFrame: @Sendable (SpacesDeviceWorkspaceFileListSignatureFrame) -> Void
    private let onDisconnect: @Sendable ((any Error)?) -> Void
    private let connectionLock = NSLock()
    private var connection: (any SpacesPinnedTLSLineConnection)?

    public init(
        workspaceID: String, authToken: String?, clientApp: SpacesDeviceClientApp?, resolver: SpacesDeviceEndpointResolver,
        onFrame: @escaping @Sendable (SpacesDeviceWorkspaceFileListSignatureFrame) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws {
        guard UInt16(exactly: resolver.port) != nil, resolver.port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.request = SpacesDeviceAPIRequest(
            command: .subscribeWorkspaceFileListSignature(SpacesDeviceWorkspaceFileListSignatureRequest(workspaceID: workspaceID)),
            authToken: authToken, clientApp: clientApp)
        self.resolver = resolver
        self.onFrame = onFrame
        self.onDisconnect = onDisconnect
    }

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
                    let frame = try SpacesDeviceWorkspaceFileListSignatureStreamCodec.decodeLine(line)
                    guard self != nil else { return }
                    onFrame(frame)
                } catch {
                    if let response = try? SpacesDeviceAPICodec.decodeResponse(line) {
                        onDisconnect(SpacesDeviceAPIRequestClientError.requestRejected(message: response.message, code: response.errorCode))
                    } else {
                        onDisconnect(error)
                    }
                    self?.stop()
                }
            },
            // These signature and overview producers broadcast on their own timers, so silence here is a
            // real stall the transport itself surfaces; only the terminal stream needs a liveness watch.
            onBytesReceived: {}, onClosed: { error in onDisconnect(error) })
    }

    public func stop() {
        connectionLock.lock()
        let activeConnection = connection
        connection = nil
        connectionLock.unlock()
        activeConnection?.cancel()
    }
}
