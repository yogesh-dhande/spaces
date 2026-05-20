import Darwin
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

    func makeCommandChannel() -> SpacesMobileBridgeCommandChannel {
        SpacesMobileBridgeCommandChannel(settings: settings, clientApp: clientAppIdentity)
    }

    func pair(
        pairingCode: String,
        commandChannel: SpacesMobileBridgeCommandChannel? = nil
    ) async throws -> String {
        let response = try await sendRequest(
            .init(command: "pair", pairingCode: pairingCode, clientApp: clientAppIdentity),
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
    ) async throws {
        let request = SpacesMobileBridgeRequest(
            command: "takeover",
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity,
            sessionID: sessionID,
            clientID: clientID
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func sendText(
        sessionID: String,
        clientID: String,
        text: String,
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
            appendNewline: appendNewline
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func sendKey(
        sessionID: String,
        clientID: String,
        key: String,
        timeout: Duration = .seconds(3),
        commandChannel: SpacesMobileBridgeCommandChannel? = nil
    ) async throws {
        let request = SpacesMobileBridgeRequest(
            command: "key",
            authToken: settings.trimmedAuthToken,
            clientApp: clientAppIdentity,
            sessionID: sessionID,
            clientID: clientID,
            key: key
        )
        let response = try await sendRequest(request, timeout: timeout, commandChannel: commandChannel)
        guard response.ok else { throw SpacesMobileBridgeClientError.requestFailed(response.message) }
    }

    func resize(
        sessionID: String,
        clientID: String,
        columns: Int,
        rows: Int,
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
            rows: rows
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
        let connection = try makeConnection()
        let request = SpacesMobileBridgeRequest(
            command: "subscribe", authToken: settings.trimmedAuthToken, clientApp: clientAppIdentity, sessionID: sessionID, clientID: clientID
        )
        let queue = DispatchQueue(label: "spaces.mobile.bridge.stream.\(sessionID).\(clientID)")
        StreamSubscription(connection: connection, request: request, onEvent: onEvent, onDisconnect: onDisconnect).start(on: queue)
        return SpacesMobileBridgeStreamHandle { connection.cancel() }
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

actor SpacesMobileBridgeCommandChannel {
    private let host: String
    private let port: Int
    private let clientApp: SpacesMobileClientApp
    private let authToken: String?
    private var socketFD: Int32 = -1

    init(settings: SpacesMobileConnectionSettings, clientApp: SpacesMobileClientApp) {
        host = settings.trimmedHost
        port = settings.port
        authToken = settings.trimmedAuthToken
        self.clientApp = clientApp
    }

    func close() {
        guard socketFD >= 0 else { return }
        shutdown(socketFD, SHUT_RDWR)
        Darwin.close(socketFD)
        socketFD = -1
    }

    func send(request: SpacesMobileBridgeRequest, timeout: Duration) async throws -> SpacesMobileBridgeResponse {
        guard !host.isEmpty, port > 0 else { throw SpacesMobileBridgeClientError.invalidEndpoint }
        var request = request
        if request.authToken == nil {
            request = SpacesMobileBridgeRequest(
                command: request.command,
                authToken: authToken,
                pairingCode: request.pairingCode,
                clientApp: request.clientApp ?? clientApp,
                sessionID: request.sessionID,
                clientID: request.clientID,
                client: request.client,
                attachmentMode: request.attachmentMode,
                text: request.text,
                key: request.key,
                columns: request.columns,
                rows: request.rows,
                appendNewline: request.appendNewline
            )
        }
        let socketFD = try connectIfNeeded(timeout: timeout)
        do {
            try Self.writeAll(data: encodeBridgeRequestLine(request), to: socketFD)
            let responseData = try Self.readLine(from: socketFD)
            return try SpacesMobileBridgeCodec.decodeResponse(responseData)
        } catch {
            close()
            throw error
        }
    }

    private func connectIfNeeded(timeout: Duration) throws -> Int32 {
        if socketFD >= 0 {
            try Self.applySocketTimeouts(socketFD, timeout: timeout)
            return socketFD
        }

        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        let portString = String(port)
        var addressInfo: UnsafeMutablePointer<addrinfo>?
        let result = getaddrinfo(host, portString, &hints, &addressInfo)
        guard result == 0, let firstAddress = addressInfo else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { freeaddrinfo(firstAddress) }

        var currentAddress: UnsafeMutablePointer<addrinfo>? = firstAddress
        var lastError: Error = POSIXError(.ECONNREFUSED)
        while let address = currentAddress {
            let candidateFD = socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if candidateFD >= 0 {
                do {
                    try Self.setNoSIGPIPE(candidateFD)
                    try Self.applySocketTimeouts(candidateFD, timeout: timeout)
                    let connectResult = Darwin.connect(candidateFD, address.pointee.ai_addr, address.pointee.ai_addrlen)
                    if connectResult == 0 {
                        socketFD = candidateFD
                        return candidateFD
                    }
                    lastError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                } catch {
                    lastError = error
                }
                Darwin.close(candidateFD)
            } else {
                lastError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            currentAddress = address.pointee.ai_next
        }
        throw lastError
    }

    private static func applySocketTimeouts(_ socketFD: Int32, timeout: Duration) throws {
        var timeValue = timeout.timeval
        guard setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        timeValue = timeout.timeval
        guard setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func setNoSIGPIPE(_ socketFD: Int32) throws {
        var yes: Int32 = 1
        guard setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func writeAll(data: Data, to socketFD: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let written = Darwin.write(socketFD, baseAddress.advanced(by: offset), bytesRemaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                bytesRemaining -= written
                offset += written
            }
        }
    }

    private static func readLine(from socketFD: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newlineIndex = data.firstIndex(of: 0x0A) {
                let line = data.prefix(upTo: newlineIndex)
                return Data(line)
            }
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count == 0 {
                if data.isEmpty {
                    throw SpacesMobileBridgeClientError.requestFailed("The mobile bridge connection was cancelled.")
                }
                return data
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            data.append(buffer, count: count)
        }
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
