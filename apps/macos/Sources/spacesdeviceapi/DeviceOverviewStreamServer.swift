import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Unix-socket producer for the device-overview subscription. The daemon writes a
/// fresh overview line on connect and whenever `broadcast()` is called (driven by
/// database changes); the Device API server relays this socket to subscribed
/// clients on both the macOS (`NWConnection`) and Linux (`OpenSSL`) transports, so
/// the push logic lives in one place rather than once per transport.
///
/// Payload-agnostic by design (it streams whatever newline-terminated `Data` the
/// provider returns), mirroring the terminal session state stream server's socket
/// handling.
final class DeviceOverviewStreamServer: @unchecked Sendable {
    private static let writeRetrySleepInterval: TimeInterval = 0.0005

    private let socketPath: String
    private let queue: DispatchQueue
    /// Returns the current overview as one newline-terminated line, or nil if it
    /// cannot be built right now (the connection then waits for the next change).
    private let lineProvider: @Sendable () -> Data?
    private var listenSocketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]

    init(socketPath: String, queue: DispatchQueue, lineProvider: @escaping @Sendable () -> Data?) {
        self.socketPath = socketPath
        self.queue = queue
        self.lineProvider = lineProvider
    }

    func start() throws {
        try Self.removeSocketFile(at: socketPath)
        let socketFD = socket(AF_UNIX, Self.streamSocketType, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        try Self.setNoSIGPIPE(socketFD)
        var address = try Self.makeSocketAddress(path: socketPath)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
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
        try Self.setNonBlocking(socketFD)
        listenSocketFD = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptReadyConnections() }
        source.setCancelHandler { [weak self] in self?.handleAcceptSourceCancel() }
        acceptSource = source
        source.resume()
    }

    func stop() {
        queue.async {
            for fd in Array(self.clientSources.keys) { self.closeClient(fd) }
            self.acceptSource?.cancel()
            self.acceptSource = nil
        }
    }

    /// Pushes the current overview to all connected subscribers.
    func broadcast() {
        queue.async {
            guard !self.clientSources.isEmpty, let data = self.lineProvider() else { return }
            for fd in Array(self.clientSources.keys) where !Self.writeAll(data: data, to: fd) { self.closeClient(fd) }
        }
    }

    private func acceptReadyConnections() {
        while true {
            let clientFD = accept(listenSocketFD, nil, nil)
            if clientFD < 0 { return }
            do {
                try Self.setNoSIGPIPE(clientFD)
                try Self.setNonBlocking(clientFD)
                let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
                source.setEventHandler { [weak self] in self?.drainClientInput(clientFD) }
                source.setCancelHandler { close(clientFD) }
                clientSources[clientFD] = source
                source.resume()
                if let data = lineProvider(), !Self.writeAll(data: data, to: clientFD) { closeClient(clientFD) }
            } catch { close(clientFD) }
        }
    }

    private func drainClientInput(_ clientFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(clientFD, &buffer, buffer.count)
            if count == 0 {
                closeClient(clientFD)
                return
            }
            if count < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { return }
                closeClient(clientFD)
                return
            }
        }
    }

    private func closeClient(_ clientFD: Int32) {
        guard let source = clientSources.removeValue(forKey: clientFD) else { return }
        source.cancel()
    }

    private func handleAcceptSourceCancel() {
        if listenSocketFD >= 0 { close(listenSocketFD) }
        listenSocketFD = -1
        try? Self.removeSocketFile(at: socketPath)
    }

    private static func removeSocketFile(at path: String) throws {
        guard path.withCString({ unlink($0) }) != 0 else { return }
        if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func makeSocketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8Path = path.utf8CString
        guard utf8Path.count <= maxLength else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            utf8Path.withUnsafeBufferPointer { if let baseAddress = $0.baseAddress { memcpy(pointer, baseAddress, $0.count) } }
        }
        return address
    }

    private static func setNonBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0, fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func setNoSIGPIPE(_ fileDescriptor: Int32) throws {
        #if canImport(Darwin)
            var yes: Int32 = 1
            guard setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        #else
            _ = fileDescriptor
        #endif
    }

    private static func writeAll(data: Data, to fileDescriptor: Int32) -> Bool {
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var bytesRemaining = rawBuffer.count
                var offset = 0
                while bytesRemaining > 0 {
                    let written = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                    if written < 0 {
                        if errno == EWOULDBLOCK || errno == EAGAIN {
                            Thread.sleep(forTimeInterval: writeRetrySleepInterval)
                            continue
                        }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    bytesRemaining -= written
                    offset += written
                }
            }
            return true
        } catch { return false }
    }

    private static var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }
}
