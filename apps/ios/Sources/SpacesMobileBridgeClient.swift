import Darwin
import Foundation
import Network
import spacesmobilecore
import spacesterminalcore

enum SpacesMobileBridgeClientError: LocalizedError {
    case invalidEndpoint
    case requestFailed(String)
    case transportAuthenticationFailed
    case missingOverview
    case streamFailed(String)
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The mobile bridge host or port is invalid."
        case .requestFailed(let message):
            message
        case .transportAuthenticationFailed:
            "The secure mobile bridge transport could not authenticate."
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

    func makeCommandChannel() -> SpacesMobileBridgeCommandChannel {
        SpacesMobileBridgeCommandChannel(settings: settings, clientApp: clientAppIdentity)
    }

    func pair(pairingLink: SpacesMobilePairingLink, commandChannel: SpacesMobileBridgeCommandChannel? = nil) async throws -> String {
        let response = try await sendRequest(
            .init(command: "pair", pairingCode: pairingLink.code, pairingNonce: pairingLink.nonce, clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
        guard let issuedAuthToken = response.issuedAuthToken else {
            throw SpacesMobileBridgeClientError.requestFailed("The mobile bridge did not return an auth token.")
        }
        return issuedAuthToken
    }

    func fetchOverview(commandChannel: SpacesMobileBridgeCommandChannel? = nil) async throws -> SpacesMobileOverviewPayload {
        let response = try await sendRequest(
            .init(command: "overview", authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity),
            commandChannel: commandChannel
        )
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
        guard let overview = response.overview else { throw SpacesMobileBridgeClientError.missingOverview }
        return overview
    }

    func fetchState(
        sessionID: String,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesMobileBridgeCommandChannel? = nil
    ) async throws -> GhosttyRemoteSessionStatePayload {
        let request = SpacesMobileBridgeRequest(
            command: "state",
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity,
            sessionID: sessionID
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
        guard let sessionState = response.sessionState else {
            throw SpacesMobileBridgeClientError.requestFailed("The mobile bridge did not return terminal state.")
        }
        return sessionState
    }

    func attach(
        sessionID: String,
        client: TerminalClient,
        mode: TerminalAttachmentMode,
        commandChannel: SpacesMobileBridgeCommandChannel? = nil
    ) async throws {
        let request = SpacesMobileBridgeRequest(
            command: "attach",
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity,
            sessionID: sessionID,
            client: client,
            attachmentMode: mode
        )
        let response = try await sendRequest(request, commandChannel: commandChannel)
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func detach(
        sessionID: String,
        clientID: String,
        commandChannel: SpacesMobileBridgeCommandChannel? = nil
    ) async throws {
        let request = SpacesMobileBridgeRequest(
            command: "detach",
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity,
            sessionID: sessionID,
            clientID: clientID
        )
        let response = try await sendRequest(request, commandChannel: commandChannel)
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func takeOver(
        sessionID: String,
        clientID: String,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesMobileBridgeCommandChannel? = nil
    ) async throws -> GhosttyRemoteSessionStatePayload? {
        let request = SpacesMobileBridgeRequest(
            command: "takeover",
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity,
            sessionID: sessionID,
            clientID: clientID
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
        return response.sessionState
    }

    func sendText(
        sessionID: String,
        clientID: String,
        text: String,
        ownerEpoch: UInt64?,
        appendNewline: Bool = false,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesMobileBridgeCommandChannel? = nil
    ) async throws {
        let request = SpacesMobileBridgeRequest(
            command: "send",
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity,
            sessionID: sessionID,
            clientID: clientID,
            text: text,
            ownerEpoch: ownerEpoch,
            appendNewline: appendNewline
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func sendKey(
        sessionID: String,
        clientID: String,
        key: String,
        ownerEpoch: UInt64?,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesMobileBridgeCommandChannel? = nil
    ) async throws {
        let request = SpacesMobileBridgeRequest(
            command: "key",
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity,
            sessionID: sessionID,
            clientID: clientID,
            key: key,
            ownerEpoch: ownerEpoch
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func clearScreen(
        sessionID: String,
        clientID: String,
        ownerEpoch: UInt64?,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesMobileBridgeCommandChannel? = nil
    ) async throws {
        let request = SpacesMobileBridgeRequest(
            command: "clearScreen",
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity,
            sessionID: sessionID,
            clientID: clientID,
            ownerEpoch: ownerEpoch
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func resize(
        sessionID: String,
        clientID: String,
        columns: Int,
        rows: Int,
        ownerEpoch: UInt64?,
        resizeSerial: UInt64?,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesMobileBridgeCommandChannel? = nil
    ) async throws {
        let request = SpacesMobileBridgeRequest(
            command: "resize",
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity,
            sessionID: sessionID,
            clientID: clientID,
            columns: columns,
            rows: rows,
            ownerEpoch: ownerEpoch,
            resizeSerial: resizeSerial
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func scroll(
        sessionID: String,
        clientID: String,
        horizontal: Double,
        vertical: Double,
        ownerEpoch: UInt64?,
        scrollMods: Int32? = nil,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesMobileBridgeCommandChannel? = nil
    ) async throws {
        let request = SpacesMobileBridgeRequest(
            command: "scroll",
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity,
            sessionID: sessionID,
            clientID: clientID,
            ownerEpoch: ownerEpoch,
            scrollHorizontal: horizontal,
            scrollVertical: vertical,
            scrollMods: scrollMods
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func subscribe(
        sessionID: String,
        clientID: String,
        onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (Error?) -> Void
    ) throws -> SpacesMobileBridgeStreamHandle {
        let endpoint = try makeConnection()
        let request = SpacesMobileBridgeRequest(
            command: "subscribe", authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity, sessionID: sessionID, clientID: clientID
        )
        let queue = DispatchQueue(label: "spaces.mobile.bridge.stream.\(sessionID).\(clientID)")
        StreamSubscription(
            connection: endpoint.connection, host: endpoint.host, port: endpoint.port, request: request, onEvent: onEvent, onDisconnect: onDisconnect
        )
        .start(on: queue)
        return SpacesMobileBridgeStreamHandle { endpoint.connection.cancel() }
    }

    private func sendRequest(_ request: SpacesMobileBridgeRequest, timeout: Duration = .seconds(3)) async throws -> SpacesMobileBridgeResponse {
        try await sendRequest(request, timeout: timeout, commandChannel: nil)
    }

    private func sendRequest(
        _ request: SpacesMobileBridgeRequest,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesMobileBridgeCommandChannel?
    ) async throws -> SpacesMobileBridgeResponse {
        if let commandChannel {
            return try await commandChannel.send(request: request, timeout: timeout)
        }
        let temporaryCommandChannel = makeCommandChannel()
        do {
            let response = try await temporaryCommandChannel.send(request: request, timeout: timeout)
            await temporaryCommandChannel.close()
            return response
        } catch {
            await temporaryCommandChannel.close()
            throw error
        }
    }

    private func makeConnection() throws -> (connection: NWConnection, host: String, port: NWEndpoint.Port) {
        let host = settings.trimmedHost
        guard let port = NWEndpoint.Port(rawValue: UInt16(settings.port)), !host.isEmpty else {
            throw SpacesMobileBridgeClientError.invalidEndpoint
        }
        let parameters = try SpacesMobileBridgeTransport.parameters(transportKey: settings.transportKey, role: .client)
        return (NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters), host, port)
    }

    private var clientAppIdentity: SpacesMobileClientApp {
        SpacesMobileClientApp(
            installationID: settings.installationID,
            bundleID: Bundle.main.bundleIdentifier ?? SpacesMobileFirstPartyPolicy.allowedBundleID,
            platform: "ios",
            deviceName: ProcessInfo.processInfo.hostName,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
    }

}

actor SpacesMobileBridgeCommandChannel {
    private let host: String
    private let port: Int
    private let transportKey: String
    private let clientApp: SpacesMobileClientApp
    private let authToken: String?
    private let queue = DispatchQueue(label: "spaces.mobile.bridge.command")
    private var connection: NWConnection?

    init(settings: SpacesMobileConnectionSettings, clientApp: SpacesMobileClientApp) {
        host = settings.trimmedHost
        port = settings.port
        transportKey = settings.transportKey
        authToken = settings.trimmedAuthToken
        self.clientApp = clientApp
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    func send(request: SpacesMobileBridgeRequest, timeout: Duration) async throws -> SpacesMobileBridgeResponse {
        guard !host.isEmpty, port > 0 else { throw SpacesMobileBridgeClientError.invalidEndpoint }
        var request = request
        if request.authToken == nil {
            request = SpacesMobileBridgeRequest(
                command: request.command,
                authToken: authToken,
                pairingCode: request.pairingCode,
                pairingNonce: request.pairingNonce,
                clientApp: request.clientApp ?? clientApp,
                sessionID: request.sessionID,
                clientID: request.clientID,
                client: request.client,
                attachmentMode: request.attachmentMode,
                text: request.text,
                key: request.key,
                columns: request.columns,
                rows: request.rows,
                ownerEpoch: request.ownerEpoch,
                resizeSerial: request.resizeSerial,
                scrollHorizontal: request.scrollHorizontal,
                scrollVertical: request.scrollVertical,
                scrollMods: request.scrollMods,
                appendNewline: request.appendNewline
            )
        }
        let connection = try await connectIfNeeded(timeout: timeout)
        do {
            try await Self.send(data: encodeBridgeRequestLine(request), on: connection, timeout: timeout)
            let responseData = try await Self.readLine(from: connection, timeout: timeout)
            return try SpacesMobileBridgeCodec.decodeResponse(responseData)
        } catch {
            close()
            throw error
        }
    }

    private func connectIfNeeded(timeout: Duration) async throws -> NWConnection {
        if let connection { return connection }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw SpacesMobileBridgeClientError.invalidEndpoint }
        let parameters = try SpacesMobileBridgeTransport.parameters(transportKey: transportKey, role: .client)
        let createdConnection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        do {
            try await SpacesMobileBridgeConnectionSupport.waitUntilReady(createdConnection, queue: queue, timeout: timeout)
        } catch {
            createdConnection.cancel()
            if SpacesMobileBridgeConnectionSupport.isRequestTimedOut(error),
                await SpacesMobileBridgeConnectionSupport.canOpenPlainTCPConnection(host: host, port: nwPort, timeout: .milliseconds(750))
            {
                throw SpacesMobileBridgeClientError.transportAuthenticationFailed
            }
            throw error
        }
        connection = createdConnection
        return createdConnection
    }

    private static func send(data: Data, on connection: NWConnection, timeout: Duration) async throws {
        try await SpacesMobileBridgeConnectionSupport.withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume = OneShotContinuation(continuation)
                connection.send(content: data, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
                    if let error {
                        resume.resume(throwing: error)
                    } else {
                        resume.resume(returning: ())
                    }
                })
            }
        }
    }

    private static func readLine(from connection: NWConnection, timeout: Duration) async throws -> Data {
        try await SpacesMobileBridgeConnectionSupport.withTimeout(timeout) {
            try await readLineAccumulating(from: connection, data: Data())
        }
    }

    private static func readLineAccumulating(from connection: NWConnection, data: Data) async throws -> Data {
        if let newlineIndex = data.firstIndex(of: 0x0A) {
            return Data(data.prefix(upTo: newlineIndex))
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resume = OneShotContinuation(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    resume.resume(throwing: error)
                    return
                }
                var nextData = data
                if let content, !content.isEmpty { nextData.append(content) }
                if let newlineIndex = nextData.firstIndex(of: 0x0A) {
                    resume.resume(returning: Data(nextData.prefix(upTo: newlineIndex)))
                    return
                }
                if isComplete {
                    if nextData.isEmpty {
                        resume.resume(throwing: SpacesMobileBridgeClientError.requestFailed("The mobile bridge connection was cancelled."))
                    } else {
                        resume.resume(returning: nextData)
                    }
                    return
                }
                Task {
                    do {
                        resume.resume(returning: try await readLineAccumulating(from: connection, data: nextData))
                    } catch {
                        resume.resume(throwing: error)
                    }
                }
            }
        }
    }
}

private enum SpacesMobileBridgeConnectionSupport {
    static func waitUntilReady(_ connection: NWConnection, queue: DispatchQueue, timeout: Duration) async throws {
        try await withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resume = OneShotContinuation(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resume.resume(returning: ())
                    case .failed(let error):
                        resume.resume(throwing: error)
                    case .cancelled:
                        resume.resume(throwing: SpacesMobileBridgeClientError.requestFailed("The mobile bridge connection was cancelled."))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    static func canOpenPlainTCPConnection(host: String, port: NWEndpoint.Port, timeout: Duration) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        do {
            try await waitUntilReady(connection, queue: DispatchQueue(label: "spaces.mobile.bridge.tcp-probe"), timeout: timeout)
            connection.cancel()
            return true
        } catch {
            connection.cancel()
            return false
        }
    }

    static func isRequestTimedOut(_ error: Error) -> Bool {
        if case SpacesMobileBridgeClientError.requestTimedOut = error { return true }
        return false
    }

    static func pendingSecureConnectionTimeoutError(host: String, port: NWEndpoint.Port) async -> Error {
        if await canOpenPlainTCPConnection(host: host, port: port, timeout: .milliseconds(750)) {
            return SpacesMobileBridgeClientError.transportAuthenticationFailed
        }
        return SpacesMobileBridgeClientError.streamFailed("Timed out waiting for terminal state.")
    }

    static func withTimeout<T: Sendable>(_ timeout: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let timeoutState = TimeoutOperationHolder<T>()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                let operationState = TimeoutOperation(continuation)
                timeoutState.set(operationState)

                let operationTask = Task {
                    do {
                        operationState.resume(returning: try await operation())
                    } catch {
                        operationState.resume(throwing: error)
                    }
                }
                operationState.addTask(operationTask)

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    operationState.resume(throwing: SpacesMobileBridgeClientError.requestTimedOut)
                }
                operationState.addTask(timeoutTask)
            }
        } onCancel: {
            timeoutState.cancel()
        }
    }
}

private final class TimeoutOperationHolder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: TimeoutOperation<T>?

    func set(_ operation: TimeoutOperation<T>) {
        lock.lock()
        self.operation = operation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let operation = operation
        self.operation = nil
        lock.unlock()
        operation?.resume(throwing: CancellationError())
    }
}

private final class TimeoutOperation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var tasks: [Task<Void, Never>] = []

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func addTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = continuation == nil
        if !shouldCancel { tasks.append(task) }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func resume(returning value: T) {
        finish { continuation in
            continuation.resume(returning: value)
        }
    }

    func resume(throwing error: any Error) {
        finish { continuation in
            continuation.resume(throwing: error)
        }
    }

    private func finish(_ resume: (CheckedContinuation<T, any Error>) -> Void) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let tasks = tasks
        self.tasks = []
        lock.unlock()

        for task in tasks { task.cancel() }
        resume(continuation)
    }
}

private final class OneShotContinuation<T: Sendable>: @unchecked Sendable {
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
    private static let initialEventTimeout: Duration = .seconds(12)

    private let connection: NWConnection
    private let host: String
    private let port: NWEndpoint.Port
    private let request: SpacesMobileBridgeRequest
    private let lifecycle: StreamLifecycle
    private let onEvent: @MainActor (GhosttyRemoteSessionStatePayload) -> Void
    private var buffer = Data()
    private var decodedState = false
    private var connectionReady = false

    init(
        connection: NWConnection,
        host: String,
        port: NWEndpoint.Port,
        request: SpacesMobileBridgeRequest,
        onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (Error?) -> Void
    ) {
        self.connection = connection
        self.host = host
        self.port = port
        self.request = request
        self.onEvent = onEvent
        lifecycle = StreamLifecycle(onDisconnect: onDisconnect)
    }

    func start(on queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + Self.initialEventTimeout.timeInterval) { [weak self] in
            guard let self, !decodedState else { return }
            guard !connectionReady else {
                lifecycle.finish(error: SpacesMobileBridgeClientError.streamFailed("Timed out waiting for terminal state."))
                connection.cancel()
                return
            }
            let host = host
            let port = port
            Task { [weak self] in
                let error = await SpacesMobileBridgeConnectionSupport.pendingSecureConnectionTimeoutError(host: host, port: port)
                queue.async { [weak self] in
                    guard let self, !decodedState else { return }
                    if connectionReady {
                        lifecycle.finish(error: SpacesMobileBridgeClientError.streamFailed("Timed out waiting for terminal state."))
                    } else {
                        lifecycle.finish(error: error)
                    }
                    connection.cancel()
                }
            }
        }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connectionReady = true
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
                        if let response = try? SpacesMobileBridgeCodec.decodeResponse(line), !response.ok {
                            lifecycle.finish(error: SpacesMobileBridgeClientError.streamFailed(response.message))
                            connection.cancel()
                            return
                        }
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

private extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }

    var timeval: timeval {
        let wholeSeconds = Int(timeInterval.rounded(.down))
        let microseconds = Int32((timeInterval - TimeInterval(wholeSeconds)) * 1_000_000)
        return Darwin.timeval(tv_sec: wholeSeconds, tv_usec: microseconds)
    }
}

private func encodeBridgeRequestLine(_ request: SpacesMobileBridgeRequest) throws -> Data {
    var data = try SpacesMobileBridgeCodec.encodeRequest(request)
    data.append(0x0A)
    return data
}
