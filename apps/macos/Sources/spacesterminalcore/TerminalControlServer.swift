import Dispatch
import Foundation

public final class TerminalControlServer: @unchecked Sendable {
    private let socketPath: String
    private let queue: DispatchQueue
    private let handleRequest: @Sendable (TerminalControlRequest) throws -> TerminalControlResponse
    private var listenSocketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public init(
        socketPath: String, queue: DispatchQueue, handleRequest: @escaping @Sendable (TerminalControlRequest) throws -> TerminalControlResponse
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
                let request = try TerminalControlCodec.decodeRequest(requestData)
                let response = try handleRequest(request)
                let responseData = try TerminalControlCodec.encodeResponse(response)
                try Self.writeAll(data: responseData, to: clientFD)
            } catch {
                let fallback = TerminalControlResponse(ok: false, message: String(describing: error))
                if let data = try? TerminalControlCodec.encodeResponse(fallback) { try? Self.writeAll(data: data, to: clientFD) }
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
