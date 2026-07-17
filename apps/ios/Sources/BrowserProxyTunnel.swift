import Foundation
import Network
import spacesdevicecore
import spacesterminalcore

/// A daemon connection that has been handed over to a raw byte tunnel: the single `ok` response line
/// has already been read off `connection`, and `residual` holds any bytes that arrived in the same
/// read after that line's trailing newline (early service output the proxy must forward to the
/// browser before it starts splicing).
struct OpenedTunnel: Sendable {
    let connection: NWConnection
    let residual: Data
}

/// Opens an authenticated raw-byte tunnel to a workspace service on the owning daemon. Abstracted so
/// the proxy can be driven by a fake in tests without a live daemon.
protocol BrowserTunnelDialing: Sendable { func openTunnel(to target: BrowserProxyRouteTarget) async throws -> OpenedTunnel }

/// A typed tunnel-open failure carrying the daemon's machine-readable error code (when present) so
/// the proxy can pick the right HTTP status: `serviceNotRunning` becomes a 503, everything else a 502.
struct BrowserTunnelError: Error, Equatable {
    let code: SpacesDeviceErrorCode?
    let message: String

    init(code: SpacesDeviceErrorCode?, message: String) {
        self.code = code
        self.message = message
    }
}

/// The production dialer: opens a pinned-TLS connection to the daemon, sends an `openServiceTunnel`
/// request authenticated with the device's Keychain auth token, reads the one `ok` response line, and
/// hands the now-raw connection back for splicing.
struct SpacesMobileBrowserTunnelDialer: BrowserTunnelDialing {
    private let installationID: String
    private let connectTimeout: Duration
    private let responseTimeout: Duration

    init(installationID: String, connectTimeout: Duration = .seconds(10), responseTimeout: Duration = .seconds(10)) {
        self.installationID = installationID
        self.connectTimeout = connectTimeout
        self.responseTimeout = responseTimeout
    }

    func openTunnel(to target: BrowserProxyRouteTarget) async throws -> OpenedTunnel {
        guard let authToken = SpacesMobileDeviceStore.authToken(deviceID: target.deviceID) else {
            throw BrowserTunnelError(code: .unauthorized, message: "This device is not paired anymore. Re-pair it in Spaces settings.")
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(target.port)) else {
            throw BrowserTunnelError(code: .invalidArgument, message: "The device has an invalid Device API port.")
        }

        let parameters = SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: target.certificateFingerprint)
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "spaces.mobile.browser.tunnel")

        do {
            try await BrowserProxyConnectionIO.withTimeout(connectTimeout) {
                try await BrowserProxyConnectionIO.waitUntilReady(connection, queue: queue)
            }
            let request = SpacesDeviceAPIRequest(
                command: .openServiceTunnel(.init(workspaceID: target.workspaceID, serviceName: target.serviceName)), authToken: authToken,
                clientApp: clientApp)
            var line = try SpacesDeviceAPICodec.encodeRequest(request)
            line.append(0x0A)
            try await BrowserProxyConnectionIO.send(line, on: connection)

            let (responseLine, residual) = try await BrowserProxyConnectionIO.withTimeout(responseTimeout) {
                try await BrowserProxyConnectionIO.readLineWithResidual(from: connection)
            }
            let response = try SpacesDeviceAPICodec.decodeResponse(responseLine)
            guard response.ok else { throw BrowserTunnelError(code: response.errorCode, message: response.message) }
            return OpenedTunnel(connection: connection, residual: residual)
        } catch let error as BrowserTunnelError {
            connection.cancel()
            throw error
        } catch {
            connection.cancel()
            throw BrowserTunnelError(code: nil, message: "The connection to the device failed.")
        }
    }

    private var clientApp: SpacesDeviceClientApp {
        SpacesDeviceClientApp(
            installationID: installationID, bundleID: Bundle.main.bundleIdentifier ?? SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
            deviceName: ProcessInfo.processInfo.hostName, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }
}

/// Async wrappers over `NWConnection`'s callback API, shared by the tunnel dialer and the proxy's
/// splice loop. Mirrors the continuation-hop style used by `SpacesDeviceAPICommandChannel`.
enum BrowserProxyConnectionIO {
    enum IOError: Error, Equatable {
        case cancelled
        case closedBeforeResponse
        case timedOut
    }

    static func waitUntilReady(_ connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resume = BrowserProxyOneShot(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: resume.resume(returning: ())
                case .waiting(let error):
                    // NWConnection treats a refused connect as retryable and would redial forever;
                    // a proxy dial must fail fast instead so the browser gets an error page.
                    resume.resume(throwing: error)
                case .failed(let error): resume.resume(throwing: error)
                case .cancelled: resume.resume(throwing: IOError.cancelled)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resume = BrowserProxyOneShot(continuation)
            connection.send(
                content: data, contentContext: .defaultMessage, isComplete: false,
                completion: .contentProcessed { error in if let error { resume.resume(throwing: error) } else { resume.resume(returning: ()) } })
        }
    }

    /// Reads until the first newline, returning the line (without the newline) and any bytes that
    /// followed it in the same read. Those trailing bytes are tunnel payload, not framing.
    static func readLineWithResidual(from connection: NWConnection, accumulated: Data = Data()) async throws -> (line: Data, residual: Data) {
        if let newlineIndex = accumulated.firstIndex(of: 0x0A) {
            let line = Data(accumulated[..<newlineIndex])
            let residual = Data(accumulated[accumulated.index(after: newlineIndex)...])
            return (line, residual)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(line: Data, residual: Data), any Error>) in
            let resume = BrowserProxyOneShot(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    resume.resume(throwing: error)
                    return
                }
                var next = accumulated
                if let content, !content.isEmpty { next.append(content) }
                if next.firstIndex(of: 0x0A) != nil {
                    Task {
                        do { resume.resume(returning: try await readLineWithResidual(from: connection, accumulated: next)) } catch {
                            resume.resume(throwing: error)
                        }
                    }
                    return
                }
                if isComplete {
                    resume.resume(throwing: IOError.closedBeforeResponse)
                    return
                }
                Task {
                    do { resume.resume(returning: try await readLineWithResidual(from: connection, accumulated: next)) } catch {
                        resume.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Reads one chunk of bytes, reporting stream completion. Used by the head reader and splice loop.
    static func receiveChunk(from connection: NWConnection) async throws -> (data: Data, isComplete: Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data, isComplete: Bool), any Error>) in
            let resume = BrowserProxyOneShot(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    resume.resume(throwing: error)
                    return
                }
                resume.resume(returning: (content.map { Data($0) } ?? Data(), isComplete))
            }
        }
    }

    /// Races `operation` against a sleep, throwing `.timedOut` if the sleep wins. Deliberately not a
    /// task group: `NWConnection` callback continuations do not observe task cancellation, and a
    /// throwing task group awaits all of its children before returning, which would turn a timeout
    /// into a permanent hang. The one-shot race resumes exactly once and abandons the loser.
    static func withTimeout<T: Sendable>(_ timeout: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let resume = BrowserProxyOneShot(continuation)
            let operationTask = Task { do { resume.resume(returning: try await operation()) } catch { resume.resume(throwing: error) } }
            Task {
                try? await Task.sleep(for: timeout)
                resume.resume(throwing: IOError.timedOut)
                operationTask.cancel()
            }
        }
    }
}

/// A continuation guarded so only the first `resume` takes effect, matching the pattern used across
/// the iOS Device API client's `NWConnection` callbacks.
final class BrowserProxyOneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

    func resume(returning value: T) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
