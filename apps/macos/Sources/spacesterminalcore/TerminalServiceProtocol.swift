import Dispatch
import Foundation

public struct TerminalServiceRequest: Codable, Sendable, Equatable {
    public let command: String
    public let launchConfiguration: TerminalSessionLaunchConfiguration?
    public let sessionID: String?

    public init(command: String, launchConfiguration: TerminalSessionLaunchConfiguration? = nil, sessionID: String? = nil) {
        self.command = command
        self.launchConfiguration = launchConfiguration
        self.sessionID = sessionID
    }
}

public struct TerminalServiceSessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let workingDirectory: String
    public let backend: TerminalSessionBackendKind
    public let lifetimePolicy: TerminalSessionLifetimePolicy
    public let state: TerminalSessionState
    public let servicePID: Int32
    public let childPID: Int32?
    public let controlSocketPath: String
    public let outputPath: String

    public init(
        id: String, title: String, workingDirectory: String, backend: TerminalSessionBackendKind, lifetimePolicy: TerminalSessionLifetimePolicy,
        state: TerminalSessionState, servicePID: Int32, childPID: Int32?, controlSocketPath: String, outputPath: String
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.backend = backend
        self.lifetimePolicy = lifetimePolicy
        self.state = state
        self.servicePID = servicePID
        self.childPID = childPID
        self.controlSocketPath = controlSocketPath
        self.outputPath = outputPath
    }
}

public struct TerminalServiceResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String
    public let session: TerminalServiceSessionSummary?
    public let sessions: [TerminalServiceSessionSummary]?

    public init(ok: Bool, message: String, session: TerminalServiceSessionSummary? = nil, sessions: [TerminalServiceSessionSummary]? = nil) {
        self.ok = ok
        self.message = message
        self.session = session
        self.sessions = sessions
    }
}

enum TerminalServiceCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encodeRequest(_ request: TerminalServiceRequest) throws -> Data { try encoder.encode(request) }
    static func decodeRequest(_ data: Data) throws -> TerminalServiceRequest { try decoder.decode(TerminalServiceRequest.self, from: data) }
    static func encodeResponse(_ response: TerminalServiceResponse) throws -> Data { try encoder.encode(response) }
    static func decodeResponse(_ data: Data) throws -> TerminalServiceResponse { try decoder.decode(TerminalServiceResponse.self, from: data) }
}

public final class TerminalServiceServer {
    private let socketPath: String
    private let queue: DispatchQueue
    private let handleRequest: @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
    private var listenSocketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public init(
        socketPath: String, queue: DispatchQueue, handleRequest: @escaping @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
    ) {
        self.socketPath = socketPath
        self.queue = queue
        self.handleRequest = handleRequest
    }

    public func start() throws {
        try removeSocketIfPresent()
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = try makeSocketAddress(path: socketPath)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }

        chmod(socketPath, S_IRUSR | S_IWUSR)

        guard listen(socketFD, 16) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }
        try setNonBlocking(socketFD)

        listenSocketFD = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptReadyConnections() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listenSocketFD >= 0 { close(self.listenSocketFD) }
            try? self.removeSocketIfPresent()
        }
        acceptSource = source
        source.resume()
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
    }

    private func acceptReadyConnections() {
        while true {
            let clientFD = accept(listenSocketFD, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { return }
                return
            }

            do {
                try setBlocking(clientFD)
                let requestData = try Self.readAll(from: clientFD)
                let request = try TerminalServiceCodec.decodeRequest(requestData)
                let response = try handleRequest(request)
                let responseData = try TerminalServiceCodec.encodeResponse(response)
                try Self.writeAll(data: responseData, to: clientFD)
            } catch {
                let fallback = TerminalServiceResponse(ok: false, message: String(describing: error))
                if let data = try? TerminalServiceCodec.encodeResponse(fallback) { try? Self.writeAll(data: data, to: clientFD) }
            }

            shutdown(clientFD, SHUT_RDWR)
            close(clientFD)
        }
    }

    private func removeSocketIfPresent() throws {
        if FileManager.default.fileExists(atPath: socketPath) { try FileManager.default.removeItem(atPath: socketPath) }
    }

    private func makeSocketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8Path = path.utf8CString
        guard utf8Path.count <= maxLength else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            _ = utf8Path.withUnsafeBufferPointer { buffer in memcpy(pointer, buffer.baseAddress, buffer.count) }
        }
        return address
    }

    private func setNonBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func setBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags & ~O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func writeAll(data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let written = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                if written < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                bytesRemaining -= written
                offset += written
            }
        }
    }

    private static func readAll(from fileDescriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.append(buffer, count: count)
        }
        return data
    }
}

public enum TerminalServiceClient {
    public static func send(request: TerminalServiceRequest, socketPath: String, timeout: TimeInterval = 5) throws -> TerminalServiceResponse {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(socketFD) }

        var address = try makeSocketAddress(path: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var timeValue = timeval(timeout)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))

        let payload = try TerminalServiceCodec.encodeRequest(request)
        try writeAll(data: payload, to: socketFD)
        shutdown(socketFD, SHUT_WR)

        let responseData = try readAll(from: socketFD)
        return try TerminalServiceCodec.decodeResponse(responseData)
    }

    private static func makeSocketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8Path = path.utf8CString
        guard utf8Path.count <= maxLength else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            _ = utf8Path.withUnsafeBufferPointer { buffer in memcpy(pointer, buffer.baseAddress, buffer.count) }
        }
        return address
    }

    private static func writeAll(data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let written = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                if written < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                bytesRemaining -= written
                offset += written
            }
        }
    }

    private static func readAll(from fileDescriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension timeval {
    fileprivate init(_ seconds: TimeInterval) {
        let wholeSeconds = Int(seconds.rounded(.down))
        let microseconds = Int32((seconds - TimeInterval(wholeSeconds)) * 1_000_000)
        self.init(tv_sec: wholeSeconds, tv_usec: microseconds)
    }
}
