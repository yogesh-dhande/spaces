import Foundation
import Network
import os

/// Lifecycle status of the loopback browser proxy, surfaced so the UI can show whether the local
/// listener is up or why it failed to bind.
enum BrowserProxyStatus: Sendable, Equatable {
    case idle
    case starting
    case running(port: UInt16)
    case failed(message: String)
}

/// Observable wrapper the UI reads to reflect the proxy's bind status. The actor updates it on the
/// main actor so SwiftUI observation stays consistent.
@MainActor @Observable final class BrowserProxyRuntimeState {
    var status: BrowserProxyStatus = .idle
    /// Nonisolated so the proxy actor can construct a default instance from its own nonisolated init.
    nonisolated init() {}
}

/// On-phone reverse proxy that lets WKWebView load `http://<service>.<slug>.localhost:47898/...`.
///
/// It listens on `127.0.0.1:47898`, reads each connection's first HTTP request head to learn the
/// `Host`, looks the host up in the routing table, verifies the embedded web view's unguessable proxy
/// cookie, opens an authenticated raw-byte tunnel to the owning daemon (`openServiceTunnel` over
/// pinned TLS), replays exactly one non-upgrade request after stripping the proxy cookie, then
/// half-closes the tunnel write side so the browser cannot reuse that connection with unsanitized
/// cookies. Upgrade requests then splice the two connections transparently so WebSockets pass straight
/// through. Requests it cannot route, authenticate, or dial are answered with a self-contained HTML
/// error page.
actor SpacesMobileBrowserProxy {
    /// The fixed loopback port WKWebView targets. It is stable so the `.localhost` URLs the daemon
    /// mints resolve to this proxy regardless of which daemon owns the service.
    static let fixedPort: UInt16 = 47_898

    /// Budget for reading a connection's HTTP head before giving up on it.
    private static let headReadTimeout: Duration = .seconds(10)
    private static let bindRetryLimit = 5
    private static let bindRetryBackoff: Duration = .milliseconds(200)

    nonisolated let runtimeState: BrowserProxyRuntimeState

    private let port: UInt16
    private let dialer: any BrowserTunnelDialing
    private let queue = DispatchQueue(label: "spaces.mobile.browser.proxy")
    private let log = Logger(subsystem: "dev.usespaces.spacesmobile", category: "browser-proxy")

    private var listener: NWListener?
    private var isStarting = false
    private var startToken = 0
    private var routingTable = BrowserProxyRoutingTable()
    private var sessions: [UUID: BrowserProxySession] = [:]

    /// - Parameters:
    ///   - port: listener port (defaults to `fixedPort`; injectable so tests avoid a real 47898 collision).
    ///   - installationID: this app installation's paired identity, used to build the real dialer's tunnel requests.
    ///   - dialer: tunnel opener; defaults to the production pinned-TLS dialer. Injected as a fake in tests.
    ///   - runtimeState: observable status object; defaults to a fresh one.
    init(
        port: UInt16 = SpacesMobileBrowserProxy.fixedPort, installationID: String, dialer: (any BrowserTunnelDialing)? = nil,
        runtimeState: BrowserProxyRuntimeState = BrowserProxyRuntimeState()
    ) {
        self.port = port
        self.dialer = dialer ?? SpacesMobileBrowserTunnelDialer(installationID: installationID)
        self.runtimeState = runtimeState
    }

    /// Replaces the routing table used for subsequent connections. In-flight tunnels are unaffected.
    func updateRoutes(_ table: BrowserProxyRoutingTable) { routingTable = table }

    /// Looks up the route the proxy would use for a browser `Host`.
    func routeTarget(forHost host: String) -> BrowserProxyRouteTarget? { routingTable.target(forHost: host) }

    /// Binds the loopback listener, retrying a bind failure a few times with backoff before exposing
    /// `.failed`. Idempotent: a second call while already running is a no-op.
    func start() async {
        if listener != nil || isStarting { return }
        startToken += 1
        let token = startToken
        isStarting = true
        defer { if startToken == token { isStarting = false } }
        var lastError: (any Error)?
        for attempt in 0..<Self.bindRetryLimit {
            guard startToken == token else { return }
            var pendingListener: NWListener?
            do {
                let candidate = try makeListener()
                pendingListener = candidate
                listener = candidate
                await setStatus(.starting)
                guard listener === candidate else {
                    candidate.cancel()
                    return
                }
                try await waitUntilReady(candidate)
                guard listener === candidate else {
                    candidate.cancel()
                    return
                }
                await setStatus(.running(port: port))
                return
            } catch {
                lastError = error
                if let pendingListener {
                    pendingListener.cancel()
                    guard listener === pendingListener else { return }
                    listener = nil
                }
                if attempt < Self.bindRetryLimit - 1 { try? await Task.sleep(for: Self.bindRetryBackoff) }
            }
        }
        guard startToken == token else { return }
        let message =
            lastError.map { "The on-device browser proxy could not bind to port \(port): \($0.localizedDescription)" }
            ?? "The on-device browser proxy could not bind to port \(port)."
        log.error("browser proxy bind failed: \(message, privacy: .public)")
        await setStatus(.failed(message: message))
    }

    /// Cancels the listener and tears down every live tunnel pair.
    func stop() {
        startToken += 1
        listener?.cancel()
        listener = nil
        isStarting = false
        for session in sessions.values { session.cancelAll() }
        sessions.removeAll()
        Task { await setStatus(.idle) }
    }

    private func makeListener() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw BrowserProxyConnectionIO.IOError.cancelled }
        // Keep host and port separate: the endpoint constrains the listener to loopback, while
        // NWListener(using:on:) owns the fixed-port bind.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }
        return listener
    }

    private func waitUntilReady(_ listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resume = BrowserProxyOneShot(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: resume.resume(returning: ())
                case .waiting(let error):
                    // A bind conflict (another process holding the port) surfaces as `.waiting`
                    // because Network.framework treats it as retryable; for the proxy it is a bind
                    // failure that feeds the start() retry/backoff loop.
                    resume.resume(throwing: error)
                case .failed(let error): resume.resume(throwing: error)
                case .cancelled: resume.resume(throwing: BrowserProxyConnectionIO.IOError.cancelled)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        let session = BrowserProxySession(client: connection)
        sessions[session.id] = session
        connection.start(queue: queue)
        Task { await self.serve(session) }
    }

    private func serve(_ session: BrowserProxySession) async {
        let client = session.client
        let parser: BrowserProxyHTTPHeadParser
        do { parser = try await BrowserProxyConnectionIO.withTimeout(Self.headReadTimeout) { try await Self.readHead(from: client) } } catch {
            // Malformed, oversized, or slow head: nothing routable, so just drop the connection.
            teardown(session.id)
            return
        }

        guard let host = parser.host else {
            await respondAndClose(
                session,
                BrowserProxyErrorResponse.badGateway(
                    service: nil, workspace: nil, device: nil, reason: "The request did not include a Host header, so it can’t be routed."))
            return
        }
        guard let target = routingTable.target(forHost: host) else {
            await respondAndClose(
                session,
                BrowserProxyErrorResponse.badGateway(
                    service: nil, workspace: nil, device: nil, reason: "No running workspace service is mapped to \(host)."))
            return
        }
        guard parser.cookieValue(named: BrowserProxyRequest.cookieName) == target.proxyAuthToken else {
            await respondAndClose(
                session,
                BrowserProxyErrorResponse.forbidden(
                    service: target.serviceName, workspace: target.workspaceName, device: target.deviceName,
                    reason: "This request did not come from the active Spaces browser session."))
            return
        }

        let opened: OpenedTunnel
        do { opened = try await dialer.openTunnel(to: target) } catch let error as BrowserTunnelError {
            let response: Data
            if error.code == .serviceNotRunning {
                response = BrowserProxyErrorResponse.serviceUnavailable(
                    service: target.serviceName, workspace: target.workspaceName, device: target.deviceName, reason: error.message)
            } else {
                response = BrowserProxyErrorResponse.badGateway(
                    service: target.serviceName, workspace: target.workspaceName, device: target.deviceName, reason: error.message)
            }
            await respondAndClose(session, response)
            return
        } catch {
            await respondAndClose(
                session,
                BrowserProxyErrorResponse.badGateway(
                    service: target.serviceName, workspace: target.workspaceName, device: target.deviceName,
                    reason: "The connection to \(target.deviceName) failed."))
            return
        }

        session.tunnel = opened.connection

        let requestBodyRelay: BrowserProxyRequestBodyRelay
        let bodyLimit: Int?
        if parser.isUpgradeRequest {
            requestBodyRelay = .none
            bodyLimit = nil
        } else {
            switch parser.bodyFraming {
            case .none:
                requestBodyRelay = .none
                bodyLimit = 0
            case .contentLength(let contentLength):
                let initialBodyBytesForwarded = min(parser.bodyByteCount, contentLength)
                requestBodyRelay = .contentLength(remainingBytes: max(0, contentLength - initialBodyBytesForwarded))
                bodyLimit = contentLength
            case .chunked:
                guard let progress = parser.chunkedBodyProgress else {
                    teardown(session.id)
                    return
                }
                requestBodyRelay = .chunked(bufferedBody: parser.bodyBytes(limit: progress.forwardedByteCount))
                bodyLimit = progress.forwardedByteCount
            }
        }

        do {
            // Forward any early service bytes the daemon already delivered, then replay the consumed
            // request head (and any body bytes read with it) to the service.
            if !opened.residual.isEmpty { try await BrowserProxyConnectionIO.send(opened.residual, on: client) }
            try await BrowserProxyConnectionIO.send(
                parser.consumedBytes(
                    droppingCookieNamed: BrowserProxyRequest.cookieName, forcingConnectionClose: !parser.isUpgradeRequest, bodyLimit: bodyLimit),
                on: opened.connection)
        } catch {
            teardown(session.id)
            return
        }

        if parser.isUpgradeRequest { splice(session) } else { relaySingleRequestResponse(session, requestBodyRelay: requestBodyRelay) }
    }

    /// Reads the HTTP head off a freshly accepted client connection.
    private static func readHead(from client: NWConnection) async throws -> BrowserProxyHTTPHeadParser {
        var parser = BrowserProxyHTTPHeadParser()
        while !parser.isComplete {
            let chunk = try await BrowserProxyConnectionIO.receiveChunk(from: client)
            if !chunk.data.isEmpty { try parser.append(chunk.data) }
            if parser.isComplete { break }
            if chunk.isComplete { throw BrowserProxyConnectionIO.IOError.closedBeforeResponse }
        }
        return parser
    }

    /// Writes a complete error response, then tears the connection down. The response is sent with
    /// stream completion so the FIN is queued behind the bytes before `teardown` cancels the socket,
    /// which keeps the browser from seeing a truncated error page.
    private func respondAndClose(_ session: BrowserProxySession, _ response: Data) async {
        let client = session.client
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // `.finalMessage` is what actually emits a TCP FIN; the default message context
            // ignores `isComplete` for stream protocols.
            client.send(
                content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in continuation.resume() })
        }
        teardown(session.id)
    }

    /// Splices client and tunnel transparently in both directions. Each direction half-closes its
    /// peer on stream end; the pair is torn down once both directions finish or either errors.
    private func splice(_ session: BrowserProxySession) {
        guard let tunnel = session.tunnel else {
            teardown(session.id)
            return
        }
        let client = session.client
        let id = session.id
        let coordinator = BrowserProxyRelayCoordinator { Task { await self.teardown(id) } }
        Self.pump(from: client, to: tunnel, coordinator: coordinator)
        Self.pump(from: tunnel, to: client, coordinator: coordinator)
    }

    /// Finishes the first request body, closes the service-facing write side, and relays the single
    /// response back to the client. Normal HTTP browser connections use this instead of a raw
    /// client->service splice so a keep-alive follow-up request cannot leak the proxy auth cookie.
    private func relaySingleRequestResponse(_ session: BrowserProxySession, requestBodyRelay: BrowserProxyRequestBodyRelay) {
        guard let tunnel = session.tunnel else {
            teardown(session.id)
            return
        }
        let client = session.client
        let id = session.id
        let coordinator = BrowserProxyRelayCoordinator { Task { await self.teardown(id) } }
        switch requestBodyRelay {
        case .none: Self.finishSingleRequestBody(from: client, to: tunnel, remainingBytes: 0, coordinator: coordinator)
        case .contentLength(let remainingBytes):
            Self.finishSingleRequestBody(from: client, to: tunnel, remainingBytes: remainingBytes, coordinator: coordinator)
        case .chunked(let bufferedBody): Self.finishChunkedRequestBody(from: client, to: tunnel, bufferedBody: bufferedBody, coordinator: coordinator)
        }
        Self.pump(from: tunnel, to: client, coordinator: coordinator)
    }

    /// Pumps bytes from `source` to `dest`, applying backpressure by only issuing the next receive
    /// after the prior send is processed. Forwards stream end as a half-close (`.finalMessage` is
    /// what actually emits a TCP FIN; the default message context ignores `isComplete` for stream
    /// protocols) and reports completion (clean or errored) to the coordinator.
    private static func pump(from source: NWConnection, to dest: NWConnection, coordinator: BrowserProxyRelayCoordinator) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if error != nil {
                coordinator.abort()
                return
            }
            if let content, !content.isEmpty {
                dest.send(
                    content: content, contentContext: isComplete ? .finalMessage : .defaultMessage, isComplete: isComplete,
                    completion: .contentProcessed { sendError in
                        if sendError != nil {
                            coordinator.abort()
                            return
                        }
                        if isComplete { coordinator.directionComplete() } else { pump(from: source, to: dest, coordinator: coordinator) }
                    })
            } else if isComplete {
                dest.send(
                    content: nil, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { sendError in if sendError != nil { coordinator.abort() } else { coordinator.directionComplete() }
                    })
            } else {
                pump(from: source, to: dest, coordinator: coordinator)
            }
        }
    }

    /// Sends the remaining bytes of a known-length request body, then half-closes the service-facing
    /// write side. If the client stops before the declared body is complete, the tunnel is aborted
    /// rather than forwarding a truncated request.
    private static func finishSingleRequestBody(
        from source: NWConnection, to dest: NWConnection, remainingBytes: Int, coordinator: BrowserProxyRelayCoordinator
    ) {
        guard remainingBytes > 0 else {
            dest.send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { sendError in if sendError != nil { coordinator.abort() } else { coordinator.directionComplete() } })
            return
        }

        source.receive(minimumIncompleteLength: 1, maximumLength: min(65_536, remainingBytes)) { content, _, isComplete, error in
            if error != nil {
                coordinator.abort()
                return
            }
            guard let content, !content.isEmpty else {
                if isComplete {
                    coordinator.abort()
                    return
                }
                finishSingleRequestBody(from: source, to: dest, remainingBytes: remainingBytes, coordinator: coordinator)
                return
            }

            let nextRemainingBytes = remainingBytes - content.count
            if isComplete, nextRemainingBytes > 0 {
                coordinator.abort()
                return
            }
            dest.send(
                content: content, contentContext: nextRemainingBytes == 0 ? .finalMessage : .defaultMessage, isComplete: nextRemainingBytes == 0,
                completion: .contentProcessed { sendError in
                    if sendError != nil {
                        coordinator.abort()
                    } else if nextRemainingBytes == 0 {
                        coordinator.directionComplete()
                    } else {
                        finishSingleRequestBody(from: source, to: dest, remainingBytes: nextRemainingBytes, coordinator: coordinator)
                    }
                })
        }
    }

    /// Continues a chunked request body until the terminating chunk and trailer terminator have been
    /// forwarded, then half-closes the service-facing write side. Bytes after that terminator are a
    /// pipelined request on the browser connection and are intentionally not forwarded because they
    /// would still carry the proxy auth cookie.
    private static func finishChunkedRequestBody(
        from source: NWConnection, to dest: NWConnection, bufferedBody: Data, coordinator: BrowserProxyRelayCoordinator
    ) {
        var tracker = BrowserProxyChunkedBodyTracker()
        guard let progress = tracker.consume(bufferedBody) else {
            coordinator.abort()
            return
        }
        if progress.isComplete {
            dest.send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { sendError in if sendError != nil { coordinator.abort() } else { coordinator.directionComplete() } })
            return
        }
        finishChunkedRequestBody(from: source, to: dest, tracker: tracker, coordinator: coordinator)
    }

    private static func finishChunkedRequestBody(
        from source: NWConnection, to dest: NWConnection, tracker: BrowserProxyChunkedBodyTracker, coordinator: BrowserProxyRelayCoordinator
    ) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if error != nil {
                coordinator.abort()
                return
            }
            guard let content, !content.isEmpty else {
                if isComplete {
                    coordinator.abort()
                    return
                }
                finishChunkedRequestBody(from: source, to: dest, tracker: tracker, coordinator: coordinator)
                return
            }

            var updatedTracker = tracker
            guard let progress = updatedTracker.consume(content) else {
                coordinator.abort()
                return
            }
            if isComplete, !progress.isComplete {
                coordinator.abort()
                return
            }
            let nextTracker = updatedTracker
            let bodyBytes = content.prefix(progress.forwardedByteCount)
            dest.send(
                content: bodyBytes.isEmpty ? nil : Data(bodyBytes), contentContext: progress.isComplete ? .finalMessage : .defaultMessage,
                isComplete: progress.isComplete,
                completion: .contentProcessed { sendError in
                    if sendError != nil {
                        coordinator.abort()
                    } else if progress.isComplete {
                        coordinator.directionComplete()
                    } else {
                        finishChunkedRequestBody(from: source, to: dest, tracker: nextTracker, coordinator: coordinator)
                    }
                })
        }
    }

    private func teardown(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.cancelAll()
    }

    private func setStatus(_ status: BrowserProxyStatus) async { await MainActor.run { runtimeState.status = status } }
}

private enum BrowserProxyRequestBodyRelay: Sendable {
    case none
    case contentLength(remainingBytes: Int)
    case chunked(bufferedBody: Data)
}

/// One live proxy connection: the accepted browser connection and, once dialed, its daemon tunnel.
private final class BrowserProxySession: @unchecked Sendable {
    let id = UUID()
    let client: NWConnection
    var tunnel: NWConnection?

    init(client: NWConnection) { self.client = client }

    func cancelAll() {
        client.cancel()
        tunnel?.cancel()
    }
}

/// Coordinates the two splice directions: fires the teardown once both directions half-close, or
/// immediately when either errors. Fires at most once.
private final class BrowserProxyRelayCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 2
    private var finished = false
    private let onFinish: @Sendable () -> Void

    init(onFinish: @escaping @Sendable () -> Void) { self.onFinish = onFinish }

    func directionComplete() {
        lock.lock()
        remaining -= 1
        let shouldFire = remaining <= 0 && !finished
        if shouldFire { finished = true }
        lock.unlock()
        if shouldFire { onFinish() }
    }

    func abort() {
        lock.lock()
        let shouldFire = !finished
        finished = true
        lock.unlock()
        if shouldFire { onFinish() }
    }
}
