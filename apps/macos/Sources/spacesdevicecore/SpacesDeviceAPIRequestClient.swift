import Foundation

#if canImport(Network)
    import Network

    public enum SpacesDeviceAPIRequestClientError: LocalizedError {
        case invalidPort
        case emptyResponse
        case timeout(String)

        public var errorDescription: String? {
            switch self {
            case .invalidPort: "The Device API port is invalid."
            case .emptyResponse: "The Device API connection closed before returning a response."
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
