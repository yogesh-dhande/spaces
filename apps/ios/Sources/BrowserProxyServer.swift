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
@MainActor @Observable
final class BrowserProxyRuntimeState {
    var status: BrowserProxyStatus = .idle
    /// Nonisolated so the proxy actor can construct a default instance from its own nonisolated init.
    nonisolated init() {}
}

/// On-phone reverse proxy that lets WKWebView load `http://<service>.<slug>.localhost:47898/...`.
///
/// It listens on `127.0.0.1:47898`, reads each connection's first HTTP request head to learn the
/// `Host`, looks the host up in the routing table, opens an authenticated raw-byte tunnel to the
/// owning daemon (`openServiceTunnel` over pinned TLS), replays the bytes it consumed, then splices
/// the two connections transparently so WebSocket/SSE upgrades pass straight through. Requests it
/// cannot route or dial are answered with a self-contained HTML error page.
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
    private var routingTable = BrowserProxyRoutingTable()
    private var sessions: [UUID: BrowserProxySession] = [:]

    /// - Parameters:
    ///   - port: listener port (defaults to `fixedPort`; injectable so tests avoid a real 47898 collision).
    ///   - installationID: this app installation's paired identity, used to build the real dialer's tunnel requests.
    ///   - dialer: tunnel opener; defaults to the production pinned-TLS dialer. Injected as a fake in tests.
    ///   - runtimeState: observable status object; defaults to a fresh one.
    init(
        port: UInt16 = SpacesMobileBrowserProxy.fixedPort,
        installationID: String,
        dialer: (any BrowserTunnelDialing)? = nil,
        runtimeState: BrowserProxyRuntimeState = BrowserProxyRuntimeState()
    ) {
        self.port = port
        self.dialer = dialer ?? SpacesMobileBrowserTunnelDialer(installationID: installationID)
        self.runtimeState = runtimeState
    }

    /// Replaces the routing table used for subsequent connections. In-flight tunnels are unaffected.
    func updateRoutes(_ table: BrowserProxyRoutingTable) {
        routingTable = table
    }

    /// Binds the loopback listener, retrying a bind failure a few times with backoff before exposing
    /// `.failed`. Idempotent: a second call while already running is a no-op.
    func start() async {
        if listener != nil { return }
        await setStatus(.starting)
        var lastError: (any Error)?
        for attempt in 0..<Self.bindRetryLimit {
            do {
                try await bindListener()
                await setStatus(.running(port: port))
                return
            } catch {
                lastError = error
                listener?.cancel()
                listener = nil
                if attempt < Self.bindRetryLimit - 1 {
                    try? await Task.sleep(for: Self.bindRetryBackoff)
                }
            }
        }
        let message = lastError.map { "The on-device browser proxy could not bind to port \(port): \($0.localizedDescription)" }
            ?? "The on-device browser proxy could not bind to port \(port)."
        log.error("browser proxy bind failed: \(message, privacy: .public)")
        await setStatus(.failed(message: message))
    }

    /// Cancels the listener and tears down every live tunnel pair.
    func stop() {
        listener?.cancel()
        listener = nil
        for session in sessions.values { session.cancelAll() }
        sessions.removeAll()
        Task { await setStatus(.idle) }
    }

    private func bindListener() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw BrowserProxyConnectionIO.IOError.cancelled }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resume = BrowserProxyOneShot(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resume.resume(returning: ())
                case .waiting(let error):
                    // A bind conflict (another process holding the port) surfaces as `.waiting`
                    // because Network.framework treats it as retryable; for the proxy it is a bind
                    // failure that feeds the start() retry/backoff loop.
                    resume.resume(throwing: error)
                case .failed(let error):
                    resume.resume(throwing: error)
                case .cancelled:
                    resume.resume(throwing: BrowserProxyConnectionIO.IOError.cancelled)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
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
        do {
            parser = try await BrowserProxyConnectionIO.withTimeout(Self.headReadTimeout) {
                try await Self.readHead(from: client)
            }
        } catch {
            // Malformed, oversized, or slow head: nothing routable, so just drop the connection.
            teardown(session.id)
            return
        }

        guard let host = parser.host else {
            await respondAndClose(session, BrowserProxyErrorResponse.badGateway(
                service: nil, workspace: nil, device: nil, reason: "The request did not include a Host header, so it can’t be routed."))
            return
        }
        guard let target = routingTable.target(forHost: host) else {
            await respondAndClose(session, BrowserProxyErrorResponse.badGateway(
                service: nil, workspace: nil, device: nil,
                reason: "No running workspace service is mapped to \(host)."))
            return
        }

        let opened: OpenedTunnel
        do {
            opened = try await dialer.openTunnel(to: target)
        } catch let error as BrowserTunnelError {
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
            await respondAndClose(session, BrowserProxyErrorResponse.badGateway(
                service: target.serviceName, workspace: target.workspaceName, device: target.deviceName,
                reason: "The connection to \(target.deviceName) failed."))
            return
        }

        session.tunnel = opened.connection

        do {
            // Forward any early service bytes the daemon already delivered, then replay the consumed
            // request head (and any body bytes read with it) to the service.
            if !opened.residual.isEmpty {
                try await BrowserProxyConnectionIO.send(opened.residual, on: client)
            }
            try await BrowserProxyConnectionIO.send(parser.consumedBytes, on: opened.connection)
        } catch {
            teardown(session.id)
            return
        }

        splice(session)
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
                content: response,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() })
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
        let coordinator = BrowserProxyRelayCoordinator {
            Task { await self.teardown(id) }
        }
        Self.pump(from: client, to: tunnel, coordinator: coordinator)
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
                    content: content,
                    contentContext: isComplete ? .finalMessage : .defaultMessage,
                    isComplete: isComplete,
                    completion: .contentProcessed { sendError in
                        if sendError != nil {
                            coordinator.abort()
                            return
                        }
                        if isComplete {
                            coordinator.directionComplete()
                        } else {
                            pump(from: source, to: dest, coordinator: coordinator)
                        }
                    })
            } else if isComplete {
                dest.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                coordinator.directionComplete()
            } else {
                pump(from: source, to: dest, coordinator: coordinator)
            }
        }
    }

    private func teardown(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.cancelAll()
    }

    private func setStatus(_ status: BrowserProxyStatus) async {
        await MainActor.run { runtimeState.status = status }
    }
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
