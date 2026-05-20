import Foundation
import Network
import UIKit
import spacesmobilecore
import spacesterminalcore

enum SpacesMobileBridgeClientError: LocalizedError {
    case invalidEndpoint
    case requestFailed(String)
    case missingOverview
    case streamFailed(String)
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The mobile bridge host or port is invalid."
        case .requestFailed(let message):
            message
        case .missingOverview:
            "The mobile bridge did not return a workspace or terminal overview."
        case .streamFailed(let message):
            message
        case .requestTimedOut:
            "The mobile bridge request timed out."
        }
    }
}

final class SpacesMobileBridgeStreamHandle: @unchecked Sendable {
    private let cancelHandler: @Sendable () -> Void

    init(cancelHandler: @escaping @Sendable () -> Void) { self.cancelHandler = cancelHandler }

    func cancel() { cancelHandler() }
}

struct SpacesMobileBridgeClient: Sendable {
    let settings: SpacesMobileConnectionSettings

    func pair(pairingCode: String) async throws -> String {
        let response = try await sendRequest(
            .init(command: "pair", pairingCode: pairingCode, clientApp: clientAppIdentity)
        )
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
        guard let issuedAuthToken = response.issuedAuthToken else {
            throw SpacesMobileBridgeClientError.requestFailed("The mobile bridge did not return an auth token.")
        }
        return issuedAuthToken
    }

    func fetchOverview() async throws -> SpacesMobileOverviewPayload {
        let response = try await sendRequest(.init(command: "overview", authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity))
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
        guard let overview = response.overview else { throw SpacesMobileBridgeClientError.missingOverview }
        return overview
    }

    func fetchState(sessionID: String, timeout: Duration = .seconds(3)) async throws -> GhosttyRemoteSessionStatePayload {
        let response = try await sendRequest(
            .init(command: "state", authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity, sessionID: sessionID),
            timeout: timeout
        )
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
        guard let sessionState = response.sessionState else {
            throw SpacesMobileBridgeClientError.requestFailed("The mobile bridge did not return terminal state.")
        }
        return sessionState
    }

    func attach(sessionID: String, client: TerminalClient, mode: TerminalAttachmentMode) async throws {
        let response = try await sendRequest(
            .init(
                command: "attach",
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity,
                sessionID: sessionID,
                client: client,
                attachmentMode: mode
            )
        )
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func detach(sessionID: String, clientID: String) async throws {
        let response = try await sendRequest(
            .init(command: "detach", authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity, sessionID: sessionID, clientID: clientID)
        )
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func takeOver(sessionID: String, clientID: String, timeout: Duration = .seconds(3)) async throws {
        let response = try await sendRequest(
            .init(command: "takeover", authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity, sessionID: sessionID, clientID: clientID),
            timeout: timeout
        )
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func sendText(
        sessionID: String,
        clientID: String,
        text: String,
        appendNewline: Bool = false,
        timeout: Duration = .seconds(3)
    ) async throws {
        let response = try await sendRequest(
            .init(
                command: "send",
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity,
                sessionID: sessionID,
                clientID: clientID,
                text: text,
                appendNewline: appendNewline
            ),
            timeout: timeout
        )
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func sendKey(sessionID: String, clientID: String, key: String, timeout: Duration = .seconds(3)) async throws {
        let response = try await sendRequest(
            .init(command: "key", authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity, sessionID: sessionID, clientID: clientID, key: key),
            timeout: timeout
        )
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func resize(sessionID: String, clientID: String, columns: Int, rows: Int, timeout: Duration = .seconds(3)) async throws {
        let response = try await sendRequest(
            .init(
                command: "resize",
                authToken: settings.trimmedAuthToken,
                clientApp: clientAppIdentity,
                sessionID: sessionID,
                clientID: clientID,
                columns: columns,
                rows: rows
            ),
            timeout: timeout
        )
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func subscribe(
        sessionID: String,
        clientID: String,
        onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (Error?) -> Void
    ) throws -> SpacesMobileBridgeStreamHandle {
        let connection = try makeConnection()
        let request = SpacesMobileBridgeRequest(
            command: "subscribe", authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity, sessionID: sessionID, clientID: clientID
        )
        let queue = DispatchQueue(label: "spaces.mobile.bridge.stream.\(sessionID).\(clientID)")
        StreamSubscription(connection: connection, request: request, onEvent: onEvent, onDisconnect: onDisconnect).start(on: queue)
        return SpacesMobileBridgeStreamHandle { connection.cancel() }
    }

    private func sendRequest(_ request: SpacesMobileBridgeRequest, timeout: Duration = .seconds(3)) async throws -> SpacesMobileBridgeResponse {
        let connection = try makeConnection()
        let queue = DispatchQueue(label: "spaces.mobile.bridge.request.\(UUID().uuidString)")
        return try await withCheckedThrowingContinuation { continuation in
            RequestExchange(connection: connection, request: request, timeout: timeout, continuation: continuation).start(on: queue)
        }
    }

    private func makeConnection() throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: UInt16(settings.port)), !settings.trimmedHost.isEmpty else {
            throw SpacesMobileBridgeClientError.invalidEndpoint
        }
        return NWConnection(host: NWEndpoint.Host(settings.trimmedHost), port: port, using: .tcp)
    }

    private var clientAppIdentity: SpacesMobileClientApp {
        SpacesMobileClientApp(
            installationID: settings.installationID,
            bundleID: Bundle.main.bundleIdentifier ?? SpacesMobileFirstPartyPolicy.allowedBundleID,
            platform: "ios",
            deviceName: UIDevice.current.name,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
    }

}

private final class RequestResolver<Response: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Response, Error>

    init(connection: NWConnection, continuation: CheckedContinuation<Response, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func succeed(_ response: Response) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        connection.cancel()
        continuation.resume(returning: response)
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        connection.cancel()
        continuation.resume(throwing: error)
    }
}

private final class StreamLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let onDisconnect: @MainActor (Error?) -> Void

    init(onDisconnect: @escaping @MainActor (Error?) -> Void) {
        self.onDisconnect = onDisconnect
    }

    func finish(error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        Task { @MainActor in onDisconnect(error) }
    }
}

private final class StreamSubscription: @unchecked Sendable {
    private static let initialEventTimeout: Duration = .seconds(3)

    private let connection: NWConnection
    private let request: SpacesMobileBridgeRequest
    private let lifecycle: StreamLifecycle
    private let onEvent: @MainActor (GhosttyRemoteSessionStatePayload) -> Void
    private var buffer = Data()
    private var decodedState = false

    init(
        connection: NWConnection,
        request: SpacesMobileBridgeRequest,
        onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (Error?) -> Void
    ) {
        self.connection = connection
        self.request = request
        self.onEvent = onEvent
        lifecycle = StreamLifecycle(onDisconnect: onDisconnect)
    }

    func start(on queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + Self.initialEventTimeout.timeInterval) { [weak self] in
            guard let self, !decodedState else { return }
            lifecycle.finish(error: SpacesMobileBridgeClientError.streamFailed("Timed out waiting for terminal state."))
            connection.cancel()
        }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                sendInitialRequest()
            case .failed(let error):
                lifecycle.finish(error: error)
            case .cancelled:
                lifecycle.finish(error: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendInitialRequest() {
        do {
            let data = try encodeBridgeRequestLine(request)
            connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { [self] error in
                if let error {
                    lifecycle.finish(error: error)
                    connection.cancel()
                    return
                }
                receiveNext()
            })
        } catch {
            lifecycle.finish(error: error)
            connection.cancel()
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] content, _, isComplete, error in
            if let content, !content.isEmpty {
                buffer.append(content)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer.prefix(upTo: newlineIndex))
                    buffer.removeSubrange(...newlineIndex)
                    guard !line.isEmpty else { continue }
                    do {
                        let payload = try GhosttyRemoteSessionStateCodec.decodeLine(line)
                        decodedState = true
                        Task { @MainActor in onEvent(payload) }
                    } catch {
                        lifecycle.finish(error: error)
                        connection.cancel()
                        return
                    }
                }
            }

            if let error {
                lifecycle.finish(error: error)
                connection.cancel()
                return
            }

            if isComplete {
                if !decodedState,
                    !buffer.isEmpty,
                    let response = try? SpacesMobileBridgeCodec.decodeResponse(buffer),
                    !response.ok
                {
                    lifecycle.finish(error: SpacesMobileBridgeClientError.streamFailed(response.message))
                } else {
                    lifecycle.finish(error: nil)
                }
                connection.cancel()
                return
            }

            receiveNext()
        }
    }
}

private final class RequestExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: SpacesMobileBridgeRequest
    private let timeout: Duration
    private let resolver: RequestResolver<SpacesMobileBridgeResponse>
    private var responseBuffer = Data()

    init(
        connection: NWConnection,
        request: SpacesMobileBridgeRequest,
        timeout: Duration,
        continuation: CheckedContinuation<SpacesMobileBridgeResponse, Error>
    ) {
        self.connection = connection
        self.request = request
        self.timeout = timeout
        resolver = RequestResolver(connection: connection, continuation: continuation)
    }

    func start(on queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [resolver, connection] in
            resolver.fail(SpacesMobileBridgeClientError.requestTimedOut)
            connection.cancel()
        }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                sendInitialRequest()
            case .failed(let error):
                resolver.fail(error)
            case .cancelled:
                resolver.fail(SpacesMobileBridgeClientError.requestFailed("The mobile bridge connection was cancelled."))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendInitialRequest() {
        do {
            let data = try encodeBridgeRequestLine(request)
            connection.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [self] error in
                if let error {
                    resolver.fail(error)
                    return
                }
                receiveNext()
            })
        } catch {
            resolver.fail(error)
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] content, _, isComplete, error in
            if let content, !content.isEmpty { responseBuffer.append(content) }
            if let error {
                resolver.fail(error)
                return
            }
            if isComplete {
                do {
                    let response = try SpacesMobileBridgeCodec.decodeResponse(responseBuffer)
                    resolver.succeed(response)
                } catch {
                    resolver.fail(error)
                }
                return
            }
            receiveNext()
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}

private func encodeBridgeRequestLine(_ request: SpacesMobileBridgeRequest) throws -> Data {
    var data = try SpacesMobileBridgeCodec.encodeRequest(request)
    data.append(0x0A)
    return data
}
