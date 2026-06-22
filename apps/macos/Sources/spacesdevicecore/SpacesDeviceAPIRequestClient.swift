import Foundation
import spacesterminalcore

#if canImport(Network)
    import Network

    public enum SpacesDeviceAPIRequestClientError: LocalizedError {
        case invalidPort
        case emptyResponse
        case connectionFailed(String)
        case timeout(String)

        public var errorDescription: String? {
            switch self {
            case .invalidPort: "The Device API port is invalid."
            case .emptyResponse: "The Device API connection closed before returning a response."
            case .connectionFailed(let message): message
            case .timeout(let message): message
            }
        }
    }

    public final class SpacesDeviceAPIRequestClient: @unchecked Sendable {
        private let host: String
        private let port: UInt16
        private let transportKey: String
        private let timeoutSeconds: TimeInterval

        public init(host: String, port: Int, transportKey: String, timeoutSeconds: TimeInterval = 10) throws {
            guard let port = UInt16(exactly: port), port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
            self.host = host
            self.port = port
            self.transportKey = transportKey
            self.timeoutSeconds = timeoutSeconds
        }

        public func request(_ request: SpacesDeviceAPIRequest) throws -> SpacesDeviceAPIResponse {
            try SpacesDeviceAPICodec.decodeResponse(requestData(SpacesDeviceAPICodec.encodeRequest(request)))
        }

        public func requestData(_ requestData: Data) throws -> Data {
            let connection = try makeConnection()
            defer { connection.cancel() }
            try waitUntilReady(connection)
            try send(requestData: requestData, connection: connection)
            return try receiveSingleResponse(from: connection)
        }

        private func makeConnection() throws -> NWConnection {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw SpacesDeviceAPIRequestClientError.invalidPort }
            return NWConnection(
                host: NWEndpoint.Host(host), port: endpointPort,
                using: try SpacesDeviceAPITransport.parameters(transportKey: transportKey, role: .client))
        }

        private func waitUntilReady(_ connection: NWConnection) throws {
            let queue = DispatchQueue(label: "spaces.device.api.request")
            let semaphore = DispatchSemaphore(value: 0)
            let box = SpacesDeviceAPIRequestResultBox()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: semaphore.signal()
                case .failed(let error):
                    box.setError(error)
                    semaphore.signal()
                case .cancelled:
                    box.setError(SpacesDeviceAPIRequestClientError.timeout("The Device API connection was cancelled."))
                    semaphore.signal()
                default: break
                }
            }
            connection.start(queue: queue)
            guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
                throw SpacesDeviceAPIRequestClientError.timeout("Timed out connecting to the Device API.")
            }
            if let error = box.error() { throw error }
        }

        private func send(requestData: Data, connection: NWConnection) throws {
            var payload = requestData
            payload.append(0x0A)
            let semaphore = DispatchSemaphore(value: 0)
            let box = SpacesDeviceAPIRequestResultBox()
            connection.send(
                content: payload,
                completion: .contentProcessed { error in
                    if let error { box.setError(error) }
                    semaphore.signal()
                })
            guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
                throw SpacesDeviceAPIRequestClientError.timeout("Timed out sending the Device API request.")
            }
            if let error = box.error() { throw error }
        }

        private func receiveSingleResponse(from connection: NWConnection) throws -> Data {
            let semaphore = DispatchSemaphore(value: 0)
            let box = SpacesDeviceAPIRequestResultBox()
            receiveSingleResponse(from: connection, buffered: Data(), box: box, semaphore: semaphore)
            guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
                throw SpacesDeviceAPIRequestClientError.timeout("Timed out waiting for the Device API response.")
            }
            if let error = box.error() { throw error }
            return box.responseData()
        }

        private func receiveSingleResponse(
            from connection: NWConnection, buffered data: Data, box: SpacesDeviceAPIRequestResultBox, semaphore: DispatchSemaphore
        ) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    box.setError(error)
                    semaphore.signal()
                    return
                }
                var nextData = data
                if let content { nextData.append(content) }
                if let newlineIndex = nextData.firstIndex(of: 0x0A) {
                    box.setResponseData(Data(nextData.prefix(upTo: newlineIndex)))
                    semaphore.signal()
                    return
                }
                if isComplete {
                    guard !nextData.isEmpty else {
                        box.setError(SpacesDeviceAPIRequestClientError.emptyResponse)
                        semaphore.signal()
                        return
                    }
                    box.setResponseData(nextData)
                    semaphore.signal()
                    return
                }
                self.receiveSingleResponse(from: connection, buffered: nextData, box: box, semaphore: semaphore)
            }
        }
    }

    public final class SpacesDeviceAPIRequestSessionClient: @unchecked Sendable {
        // The Linux Device API server closes idle request sockets after 120 seconds.
        // Reconnect before that so non-replayable terminal controls are written to a fresh socket.
        private static let defaultIdleReconnectInterval: TimeInterval = 90

        private let host: String
        private let port: UInt16
        private let transportKey: String
        private let idleReconnectInterval: TimeInterval
        private let uptime: @Sendable () -> TimeInterval
        private let queue = DispatchQueue(label: "spaces.device.api.request.session")
        private let requestLock = NSLock()
        private let connectionStateLock = NSLock()
        private let readBufferLock = NSLock()
        private var connection: NWConnection?
        private var connectionID: Int?
        private var activeConnectionID: Int?
        private var closedConnectionIDs: Set<Int> = []
        private var nextConnectionID = 0
        private var lastConnectionUseUptime: TimeInterval?
        private var readBuffer = Data()
        private var openedConnectionCount = 0

        public convenience init(host: String, port: Int, transportKey: String) throws {
            try self.init(
                host: host, port: port, transportKey: transportKey, idleReconnectInterval: Self.defaultIdleReconnectInterval,
                uptime: { ProcessInfo.processInfo.systemUptime })
        }

        init(host: String, port: Int, transportKey: String, idleReconnectInterval: TimeInterval, uptime: @escaping @Sendable () -> TimeInterval)
            throws
        {
            guard let port = UInt16(exactly: port), port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
            self.host = host
            self.port = port
            self.transportKey = transportKey
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
            var payload = try SpacesDeviceAPICodec.encodeRequest(request)
            payload.append(0x0A)
            try send(payload, on: activeConnection.connection, timeoutSeconds: timeoutSeconds)
            let response = try SpacesDeviceAPICodec.decodeResponse(
                readResponseLine(on: activeConnection.connection, connectionID: activeConnection.id, timeoutSeconds: timeoutSeconds))
            lastConnectionUseUptime = uptime()
            return response
        }

        private func connectionLocked(timeoutSeconds: TimeInterval) throws -> (connection: NWConnection, id: Int) {
            if let connection, let connectionID, !connectionIsClosed(connectionID), !connectionIsIdleExpired() { return (connection, connectionID) }
            closeLocked()
            let (createdConnection, createdConnectionID) = try makeConnection(timeoutSeconds: timeoutSeconds)
            connection = createdConnection
            connectionID = createdConnectionID
            activateConnection(createdConnectionID)
            lastConnectionUseUptime = uptime()
            openedConnectionCount += 1
            return (createdConnection, createdConnectionID)
        }

        private func closeLocked() {
            if let connectionID { markConnectionClosed(connectionID) }
            connection?.cancel()
            connection = nil
            connectionID = nil
            lastConnectionUseUptime = nil
            readBufferLock.lock()
            readBuffer.removeAll(keepingCapacity: true)
            readBufferLock.unlock()
        }

        private func makeConnection(timeoutSeconds: TimeInterval) throws -> (connection: NWConnection, id: Int) {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw SpacesDeviceAPIRequestClientError.invalidPort }
            let ready = DispatchSemaphore(value: 0)
            let box = SpacesDeviceAPIRequestResultBox()
            let connectionID = nextConnectionIdentifier()
            let createdConnection = NWConnection(
                host: NWEndpoint.Host(host), port: endpointPort,
                using: try SpacesDeviceAPITransport.parameters(transportKey: transportKey, role: .client))
            createdConnection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: ready.signal()
                case .failed(let error):
                    self?.markConnectionClosed(connectionID)
                    box.setError(SpacesDeviceAPIRequestClientError.connectionFailed(String(describing: error)))
                    ready.signal()
                case .cancelled: self?.markConnectionClosed(connectionID)
                default: break
                }
            }
            createdConnection.start(queue: queue)
            guard ready.wait(timeout: .now() + timeoutSeconds) == .success else {
                createdConnection.cancel()
                throw SpacesDeviceAPIRequestClientError.timeout("Timed out connecting to the Device API.")
            }
            if let error = box.error() {
                createdConnection.cancel()
                throw error
            }
            return (createdConnection, connectionID)
        }

        private func nextConnectionIdentifier() -> Int {
            connectionStateLock.lock()
            defer { connectionStateLock.unlock() }
            nextConnectionID += 1
            return nextConnectionID
        }

        private func markConnectionClosed(_ id: Int) {
            connectionStateLock.lock()
            closedConnectionIDs.insert(id)
            if activeConnectionID == id { activeConnectionID = nil }
            connectionStateLock.unlock()
        }

        private func activateConnection(_ id: Int) {
            connectionStateLock.lock()
            activeConnectionID = id
            connectionStateLock.unlock()
        }

        private func connectionIsClosed(_ id: Int) -> Bool {
            connectionStateLock.lock()
            let isClosed = closedConnectionIDs.contains(id)
            connectionStateLock.unlock()
            return isClosed
        }

        private func connectionIsCurrent(_ id: Int) -> Bool {
            connectionStateLock.lock()
            let isCurrent = activeConnectionID == id && !closedConnectionIDs.contains(id)
            connectionStateLock.unlock()
            return isCurrent
        }

        private func connectionIsIdleExpired() -> Bool {
            guard let lastConnectionUseUptime else { return false }
            return uptime() - lastConnectionUseUptime >= idleReconnectInterval
        }

        private func send(_ data: Data, on connection: NWConnection, timeoutSeconds: TimeInterval) throws {
            let sent = DispatchSemaphore(value: 0)
            let box = SpacesDeviceAPIRequestResultBox()
            connection.send(
                content: data, contentContext: .defaultMessage, isComplete: false,
                completion: .contentProcessed { error in
                    if let error { box.setError(SpacesDeviceAPIRequestClientError.connectionFailed(String(describing: error))) }
                    sent.signal()
                })
            guard sent.wait(timeout: .now() + timeoutSeconds) == .success else {
                throw SpacesDeviceAPIRequestClientError.timeout("Timed out sending the Device API request.")
            }
            if let error = box.error() { throw error }
        }

        private func readResponseLine(on connection: NWConnection, connectionID: Int, timeoutSeconds: TimeInterval) throws -> Data {
            if let bufferedLine = popBufferedResponseLine() { return bufferedLine }
            let received = DispatchSemaphore(value: 0)
            let box = SpacesDeviceAPIRequestResultBox()
            receiveLine(on: connection, connectionID: connectionID, box: box, completion: received)
            guard received.wait(timeout: .now() + timeoutSeconds) == .success else {
                throw SpacesDeviceAPIRequestClientError.timeout("Timed out waiting for the Device API response.")
            }
            if let error = box.error() { throw error }
            return box.responseData()
        }

        private func popBufferedResponseLine() -> Data? {
            readBufferLock.lock()
            defer { readBufferLock.unlock() }
            guard let newlineIndex = readBuffer.firstIndex(of: 0x0A) else { return nil }
            let line = Data(readBuffer.prefix(upTo: newlineIndex))
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            return line
        }

        private func receiveLine(on connection: NWConnection, connectionID: Int, box: SpacesDeviceAPIRequestResultBox, completion: DispatchSemaphore)
        {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] content, _, isComplete, error in
                if let error {
                    box.setError(SpacesDeviceAPIRequestClientError.connectionFailed(String(describing: error)))
                    completion.signal()
                    return
                }
                guard connectionIsCurrent(connectionID) else {
                    box.setError(SpacesDeviceAPIRequestClientError.emptyResponse)
                    completion.signal()
                    return
                }
                readBufferLock.lock()
                guard connectionIsCurrent(connectionID) else {
                    readBufferLock.unlock()
                    return
                }
                if let content, !content.isEmpty { readBuffer.append(content) }
                if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                    let line = Data(readBuffer.prefix(upTo: newlineIndex))
                    readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
                    box.setResponseData(line)
                    readBufferLock.unlock()
                    completion.signal()
                    return
                }
                if isComplete {
                    guard !readBuffer.isEmpty else {
                        box.setError(SpacesDeviceAPIRequestClientError.emptyResponse)
                        readBufferLock.unlock()
                        completion.signal()
                        return
                    }
                    box.setResponseData(readBuffer)
                    readBuffer.removeAll(keepingCapacity: true)
                    readBufferLock.unlock()
                    completion.signal()
                    return
                }
                readBufferLock.unlock()
                receiveLine(on: connection, connectionID: connectionID, box: box, completion: completion)
            }
        }

        private static func isClosedConnectionError(_ error: any Error) -> Bool {
            if case SpacesDeviceAPIRequestClientError.emptyResponse = error { return true }
            let description = String(describing: error)
            return description.localizedStandardContains("connection was cancelled")
                || description.localizedStandardContains("connection was aborted") || description.localizedStandardContains("connection reset")
                || description.localizedStandardContains("posixerrorcode: 54") || description.localizedStandardContains("broken pipe")
        }

        static func debugIsClosedConnectionErrorForTesting(_ error: any Error) -> Bool { isClosedConnectionError(error) }
    }

    public final class SpacesDeviceAPIStateStreamClient: TerminalRemoteStateStreamClient, @unchecked Sendable {
        private let request: SpacesDeviceAPIRequest
        private let host: String
        private let port: UInt16
        private let transportKey: String
        private let onEvent: @Sendable (GhosttyRemoteSessionStatePayload) -> Void
        private let onDisconnect: @Sendable ((any Error)?) -> Void
        private let queue = DispatchQueue(label: "spaces.device.api.state.stream")
        private var connection: NWConnection?
        private var buffer = Data()

        public init(
            request: SpacesDeviceAPIRequest, host: String, port: Int, transportKey: String,
            onEvent: @escaping @Sendable (GhosttyRemoteSessionStatePayload) -> Void, onDisconnect: @escaping @Sendable ((any Error)?) -> Void
        ) throws {
            guard let port = UInt16(exactly: port), port > 0 else { throw SpacesDeviceAPIRequestClientError.invalidPort }
            self.request = request
            self.host = host
            self.port = port
            self.transportKey = transportKey
            self.onEvent = onEvent
            self.onDisconnect = onDisconnect
        }

        public func start(timeoutSeconds: TimeInterval = 10) throws {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw SpacesDeviceAPIRequestClientError.invalidPort }
            let ready = DispatchSemaphore(value: 0)
            let sent = DispatchSemaphore(value: 0)
            let box = SpacesDeviceAPIRequestResultBox()
            let createdConnection = NWConnection(
                host: NWEndpoint.Host(host), port: endpointPort,
                using: try SpacesDeviceAPITransport.parameters(transportKey: transportKey, role: .client))
            createdConnection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: ready.signal()
                case .failed(let error):
                    let wrappedError = SpacesDeviceAPIRequestClientError.connectionFailed(String(describing: error))
                    box.setError(wrappedError)
                    ready.signal()
                    sent.signal()
                    self?.onDisconnect(wrappedError)
                case .cancelled: self?.onDisconnect(nil)
                default: break
                }
            }
            connection = createdConnection
            createdConnection.start(queue: queue)
            guard ready.wait(timeout: .now() + timeoutSeconds) == .success else {
                stop()
                throw SpacesDeviceAPIRequestClientError.timeout("Timed out connecting to the Device API.")
            }
            if let error = box.error() {
                stop()
                throw error
            }

            var payload = try SpacesDeviceAPICodec.encodeRequest(request)
            payload.append(0x0A)
            createdConnection.send(
                content: payload, contentContext: .defaultMessage, isComplete: false,
                completion: .contentProcessed { error in
                    if let error { box.setError(SpacesDeviceAPIRequestClientError.connectionFailed(String(describing: error))) }
                    sent.signal()
                })
            guard sent.wait(timeout: .now() + timeoutSeconds) == .success else {
                stop()
                throw SpacesDeviceAPIRequestClientError.timeout("Timed out sending the Device API subscription request.")
            }
            if let error = box.error() {
                stop()
                throw error
            }
            receiveNextLine()
        }

        public func stop() {
            connection?.cancel()
            connection = nil
        }

        private func receiveNextLine() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
                guard let self else { return }
                if let error {
                    self.onDisconnect(SpacesDeviceAPIRequestClientError.connectionFailed(String(describing: error)))
                    self.stop()
                    return
                }
                if let content { self.buffer.append(content) }
                while let newlineIndex = self.buffer.firstIndex(of: 0x0A) {
                    let line = Data(self.buffer.prefix(upTo: newlineIndex))
                    self.buffer.removeSubrange(self.buffer.startIndex...newlineIndex)
                    if !line.isEmpty {
                        do { self.onEvent(try GhosttyRemoteSessionStateCodec.decodeLine(line)) } catch {
                            self.onDisconnect(Self.streamDecodeError(for: line, fallback: error))
                            self.stop()
                            return
                        }
                    }
                }
                if isComplete {
                    self.onDisconnect(nil)
                    self.stop()
                    return
                }
                self.receiveNextLine()
            }
        }

        private static func streamDecodeError(for line: Data, fallback: any Error) -> any Error {
            guard let response = try? SpacesDeviceAPICodec.decodeResponse(line) else { return fallback }
            return SpacesDeviceAPIRequestClientError.connectionFailed(response.message)
        }
    }

    private final class SpacesDeviceAPIRequestResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedError: Error?
        private var storedResponseData = Data()

        func setError(_ error: Error) {
            lock.lock()
            storedError = error
            lock.unlock()
        }

        func error() -> Error? {
            lock.lock()
            let error = storedError
            lock.unlock()
            return error
        }

        func setResponseData(_ data: Data) {
            lock.lock()
            storedResponseData = data
            lock.unlock()
        }

        func responseData() -> Data {
            lock.lock()
            let data = storedResponseData
            lock.unlock()
            return data
        }
    }
#endif
