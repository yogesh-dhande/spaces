import Foundation

public enum TerminalControlClient {
    public static func send(request: TerminalControlRequest, socketPath: String, timeout: TimeInterval = 5) throws -> TerminalControlResponse {
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

        let payload = try TerminalControlCodec.encodeRequest(request)
        try writeAll(data: payload, to: socketFD)
        shutdown(socketFD, SHUT_WR)

        let responseData = try readAll(from: socketFD)
        return try TerminalControlCodec.decodeResponse(responseData)
    }

    public static func send(request: TerminalControlRequest, host: String, port: Int, timeout: TimeInterval = 5) throws -> TerminalControlResponse {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw POSIXError(.EADDRNOTAVAIL) }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var timeValue = timeval(timeout)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))

        let payload = try TerminalControlCodec.encodeRequest(request)
        try writeAll(data: payload, to: socketFD)
        shutdown(socketFD, SHUT_WR)

        let responseData = try readAll(from: socketFD)
        return try TerminalControlCodec.decodeResponse(responseData)
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
