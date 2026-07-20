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

/// One-shot Device API request client: opens a pinned-TLS connection per request. All Device API
/// clients authenticate the daemon by pinning its TLS identity fingerprint recorded at pairing
/// time; authorization is the bearer token inside the request payload.
public final class SpacesDeviceAPIRequestClient: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let certificateFingerprint: String
    private let timeoutSeconds: TimeInterval

    public init(host: String, port: Int, certificateFingerprint: String, timeoutSeconds: TimeInterval = 10) throws {
        guard UInt16(exactly: port) != nil, port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.host = host
        self.port = port
        self.certificateFingerprint = certificateFingerprint
        self.timeoutSeconds = timeoutSeconds
    }

    public func request(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
        try SpacesDeviceAPICodec.decodeResponse(requestData(SpacesDeviceAPICodec.encodeRequest(request)))
    }

    public func requestData(_ requestData: Data) throws -> Data {
        let connection = try SpacesPinnedTLSConnector.connect(
            host: host, port: port, certificateFingerprint: certificateFingerprint, timeout: timeoutSeconds)
        defer { connection.cancel() }
        try connection.sendLine(requestData, timeout: timeoutSeconds)
        do { return try connection.readLine(timeout: timeoutSeconds) } catch SpacesPinnedTLSConnectionError.connectionClosed {
            throw SpacesDeviceAPIRequestClientError.emptyResponse
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

    private let host: String
    private let port: Int
    private let certificateFingerprint: String
    private let idleReconnectInterval: TimeInterval
    private let uptime: @Sendable () -> TimeInterval
    private let requestLock = NSLock()
    private var connection: (any SpacesPinnedTLSLineConnection)?
    private var lastConnectionUseUptime: TimeInterval?
    private var openedConnectionCount = 0

    public convenience init(host: String, port: Int, certificateFingerprint: String) throws {
        try self.init(
            host: host, port: port, certificateFingerprint: certificateFingerprint, idleReconnectInterval: Self.defaultIdleReconnectInterval,
            uptime: { ProcessInfo.processInfo.systemUptime })
    }

    init(host: String, port: Int, certificateFingerprint: String, idleReconnectInterval: TimeInterval, uptime: @escaping @Sendable () -> TimeInterval)
        throws
    {
        guard UInt16(exactly: port) != nil, port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.host = host
        self.port = port
        self.certificateFingerprint = certificateFingerprint
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
                closeLocked()
                throw error
            }
            closeLocked()
            do { return try sendOnceLocked(request, timeoutSeconds: timeoutSeconds) } catch {
                closeLocked()
                throw error
            }
        }
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
        let createdConnection = try SpacesPinnedTLSConnector.connect(
            host: host, port: port, certificateFingerprint: certificateFingerprint, timeout: timeoutSeconds)
        connection = createdConnection
        lastConnectionUseUptime = uptime()
        openedConnectionCount += 1
        return createdConnection
    }

    private func closeLocked() {
        connection?.cancel()
        connection = nil
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

/// Reads a terminal-state subscription stream: opens a pinned-TLS Device API connection, sends
/// the subscribe request, and delivers each newline-framed state payload.
public final class SpacesDeviceAPIStateStreamClient: TerminalRemoteStateStreamClient, @unchecked Sendable {
    private let request: SpacesDeviceAPIRequest
    private let host: String
    private let port: Int
    private let certificateFingerprint: String
    private let onEvent: @Sendable (GhosttyRemoteSessionStatePayload) -> Void
    private let onDisconnect: @Sendable ((any Error)?) -> Void
    private let connectionLock = NSLock()
    private var connection: (any SpacesPinnedTLSLineConnection)?

    public init(
        request: SpacesDeviceAPIRequest, host: String, port: Int, certificateFingerprint: String,
        onEvent: @escaping @Sendable (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws {
        guard UInt16(exactly: port) != nil, port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.request = request
        self.host = host
        self.port = port
        self.certificateFingerprint = certificateFingerprint
        self.onEvent = onEvent
        self.onDisconnect = onDisconnect
    }

    public func start(timeoutSeconds: TimeInterval = 10) throws {
        let createdConnection = try SpacesPinnedTLSConnector.connect(
            host: host, port: port, certificateFingerprint: certificateFingerprint, timeout: timeoutSeconds)
        connectionLock.lock()
        connection = createdConnection
        connectionLock.unlock()
        try createdConnection.sendLine(try SpacesDeviceAPICodec.encodeRequest(request), timeout: timeoutSeconds)
        let onEvent = onEvent
        let onDisconnect = onDisconnect
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
    private let host: String
    private let port: Int
    private let certificateFingerprint: String
    private let onOverview: @Sendable (SpacesDeviceOverviewPayload) -> Void
    private let onDisconnect: @Sendable ((any Error)?) -> Void
    private let connectionLock = NSLock()
    private var connection: (any SpacesPinnedTLSLineConnection)?

    public init(
        authToken: String?, clientApp: SpacesDeviceClientApp?, host: String, port: Int, certificateFingerprint: String,
        onOverview: @escaping @Sendable (SpacesDeviceOverviewPayload) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
    ) throws {
        guard UInt16(exactly: port) != nil, port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
        self.request = SpacesDeviceAPIRequest(command: .subscribeDeviceOverview, authToken: authToken, clientApp: clientApp)
        self.host = host
        self.port = port
        self.certificateFingerprint = certificateFingerprint
        self.onOverview = onOverview
        self.onDisconnect = onDisconnect
    }

    public func start(timeoutSeconds: TimeInterval = 10) throws {
        let createdConnection = try SpacesPinnedTLSConnector.connect(
            host: host, port: port, certificateFingerprint: certificateFingerprint, timeout: timeoutSeconds)
        connectionLock.lock()
        connection = createdConnection
        connectionLock.unlock()
        try createdConnection.sendLine(try SpacesDeviceAPICodec.encodeRequest(request), timeout: timeoutSeconds)
        let onOverview = onOverview
        let onDisconnect = onDisconnect
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
