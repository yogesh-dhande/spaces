import ArgumentParser
import Darwin
import Dispatch
import Foundation
import Network
import spacesmobilecore

struct MobileRequestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "request", abstract: "Send a TLS-PSK mobile bridge JSON request for harnesses.")

    @Option(help: "Full spacesmobile:// pairing link. Supplies host, port, transport key, code, and nonce.") var pairingLink: String?

    @Option(help: "Mobile bridge host. Defaults to the pairing link host or 127.0.0.1.") var host: String?

    @Option(help: "Mobile bridge port. Defaults to the pairing link port.") var port: Int?

    @Option(help: "Base64url mobile bridge transport key. Defaults to the pairing link PSK.") var transportKey: String?

    @Option(help: "JSON bridge request. Reads stdin when omitted.") var requestJSON: String?

    @Flag(help: "Keep the connection open and print newline-delimited bridge messages.") var stream = false

    func run() throws {
        let link = try pairingLink.map { try SpacesMobilePairingLink.parse($0) }
        let resolvedHost = host ?? link?.host ?? "127.0.0.1"
        guard let resolvedPort = port ?? link?.port else { throw ValidationError("Provide --port or a pairing link.") }
        guard (1...65_535).contains(resolvedPort) else { throw ValidationError("Port must be between 1 and 65535.") }
        guard let resolvedTransportKey = transportKey ?? link?.transportKey else {
            throw ValidationError("Provide --transport-key or a pairing link.")
        }

        var requestData = try readRequestData()
        if let link { requestData = try requestDataByApplying(pairingLink: link, to: requestData) }

        let client = MobileBridgeRequestClient(host: resolvedHost, port: UInt16(resolvedPort), transportKey: resolvedTransportKey)
        if stream {
            try client.stream(requestData: requestData)
        } else {
            let responseData = try client.request(requestData: requestData)
            FileHandle.standardOutput.write(responseData)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }

    private func readRequestData() throws -> Data {
        if let requestJSON { return Data(requestJSON.utf8) }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { throw ValidationError("Provide --request-json or request JSON on stdin.") }
        return data
    }

    private func requestDataByApplying(pairingLink link: SpacesMobilePairingLink, to data: Data) throws -> Data {
        guard var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError("Request JSON must be an object.")
        }
        if payload["command"] as? String == "pair" {
            payload["pairingCode"] = payload["pairingCode"] ?? link.code
            payload["pairingNonce"] = payload["pairingNonce"] ?? link.nonce
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

private final class MobileBridgeRequestClient: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let transportKey: String

    init(host: String, port: UInt16, transportKey: String) {
        self.host = host
        self.port = port
        self.transportKey = transportKey
    }

    func request(requestData: Data) throws -> Data {
        let connection = try makeConnection()
        defer { connection.cancel() }
        try waitUntilReady(connection)
        try send(requestData: requestData, connection: connection)
        return try receiveSingleResponse(from: connection)
    }

    func stream(requestData: Data) throws -> Never {
        let connection = try makeConnection()
        try waitUntilReady(connection)
        try send(requestData: requestData, connection: connection)
        receiveStream(from: connection, buffered: Data())
        dispatchMain()
    }

    private func makeConnection() throws -> NWConnection {
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        return NWConnection(
            host: NWEndpoint.Host(host), port: endpointPort,
            using: try SpacesMobileBridgeTransport.parameters(transportKey: transportKey, role: .client))
    }

    private func waitUntilReady(_ connection: NWConnection) throws {
        let queue = DispatchQueue(label: "spaces.mobile.request")
        let semaphore = DispatchSemaphore(value: 0)
        let box = MobileBridgeRequestResultBox()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: semaphore.signal()
            case .failed(let error):
                box.setError(error)
                semaphore.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw MobileBridgeRequestError.timeout("Timed out connecting to the mobile bridge.")
        }
        if let error = box.error() { throw error }
    }

    private func send(requestData: Data, connection: NWConnection) throws {
        var payload = requestData
        payload.append(0x0A)
        let semaphore = DispatchSemaphore(value: 0)
        let box = MobileBridgeRequestResultBox()
        connection.send(
            content: payload,
            completion: .contentProcessed { error in
                if let error { box.setError(error) }
                semaphore.signal()
            })
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw MobileBridgeRequestError.timeout("Timed out sending the mobile bridge request.")
        }
        if let error = box.error() { throw error }
    }

    private func receiveSingleResponse(from connection: NWConnection) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = MobileBridgeRequestResultBox()
        receiveSingleResponse(from: connection, buffered: Data(), box: box, semaphore: semaphore)
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw MobileBridgeRequestError.timeout("Timed out waiting for the mobile bridge response.")
        }
        if let error = box.error() { throw error }
        return box.responseData()
    }

    private func receiveSingleResponse(
        from connection: NWConnection, buffered data: Data, box: MobileBridgeRequestResultBox, semaphore: DispatchSemaphore
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
                box.setResponseData(nextData)
                semaphore.signal()
                return
            }
            self.receiveSingleResponse(from: connection, buffered: nextData, box: box, semaphore: semaphore)
        }
    }

    private func receiveStream(from connection: NWConnection, buffered data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if let error {
                fputs("\(error)\n", stderr)
                exit(1)
            }
            var nextData = data
            if let content { nextData.append(content) }
            while let newlineIndex = nextData.firstIndex(of: 0x0A) {
                let line = Data(nextData.prefix(upTo: newlineIndex))
                FileHandle.standardOutput.write(line)
                FileHandle.standardOutput.write(Data([0x0A]))
                fflush(stdout)
                nextData.removeSubrange(...newlineIndex)
            }
            if isComplete { exit(0) }
            self.receiveStream(from: connection, buffered: nextData)
        }
    }
}

private enum MobileBridgeRequestError: LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let message): message
        }
    }
}

private final class MobileBridgeRequestResultBox: @unchecked Sendable {
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
