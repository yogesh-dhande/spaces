import Darwin
import Dispatch
import Foundation

public final class TerminalControlTCPServer: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let authToken: String?
    private let queue: DispatchQueue
    private let handleRequest: @Sendable (TerminalControlRequest) throws -> TerminalControlResponse
    private var listenSocketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public private(set) var listeningPort: Int = 0

    public init(
        host: String, port: Int, authToken: String? = nil, queue: DispatchQueue,
        handleRequest: @escaping @Sendable (TerminalControlRequest) throws -> TerminalControlResponse
    ) {
        self.host = host
        self.port = port
        self.authToken = authToken
        self.queue = queue
        self.handleRequest = handleRequest
    }

    public func start() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            close(socketFD)
            throw POSIXError(.EADDRNOTAVAIL)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }

        guard listen(socketFD, 16) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(socketFD)
            throw POSIXError(code)
        }
        try setNonBlocking(socketFD)

        listeningPort = try Self.resolveListeningPort(socketFD: socketFD)
        listenSocketFD = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptReadyConnections() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.listenSocketFD >= 0 { close(self.listenSocketFD) }
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
                let requestData = try TerminalControlSocketIO.readAll(from: clientFD)
                let request = try TerminalControlCodec.decodeRequest(requestData)
                let response = try validateAndHandle(request: request)
                let responseData = try TerminalControlCodec.encodeResponse(response)
                try TerminalControlSocketIO.writeAll(data: responseData, to: clientFD)
            } catch {
                let fallback = TerminalControlResponse(ok: false, message: String(describing: error))
                if let data = try? TerminalControlCodec.encodeResponse(fallback) { try? TerminalControlSocketIO.writeAll(data: data, to: clientFD) }
            }

            shutdown(clientFD, SHUT_RDWR)
            close(clientFD)
        }
    }

    private func validateAndHandle(request: TerminalControlRequest) throws -> TerminalControlResponse {
        if let authToken, authToken != request.authToken {
            return TerminalControlResponse(ok: false, message: "Unauthorized terminal client.", errorCode: .unauthorized)
        }
        if let minimum = request.minimumSupportedProtocolVersion, minimum > TerminalControlProtocolVersion.current {
            return TerminalControlResponse(
                ok: false, message: "Terminal client requires a newer protocol version.", errorCode: .unsupportedProtocolVersion)
        }
        if let requested = request.protocolVersion, requested < TerminalControlProtocolVersion.minimumSupported {
            return TerminalControlResponse(
                ok: false, message: "Terminal client uses an unsupported protocol version.", errorCode: .unsupportedProtocolVersion)
        }
        return try handleRequest(request)
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

    private static func resolveListeningPort(socketFD: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in getsockname(socketFD, sockaddrPointer, &length) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

enum TerminalControlSocketIO {
    static func writeAll(data: Data, to fileDescriptor: Int32) throws {
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

    static func readAll(from fileDescriptor: Int32) throws -> Data {
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
