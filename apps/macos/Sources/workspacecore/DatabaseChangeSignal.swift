import Dispatch
import Foundation
import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public enum DatabaseChangeSignal {
    /// Announces that a SQLiteStore write has committed. The in-process
    /// notification reaches daemon-owned writes directly. macOS also has
    /// DistributedNotificationCenter; Linux uses a profile-scoped unix socket so a
    /// separate CLI/helper process can wake the long-running daemon.
    public static func post() {
        NotificationCenter.default.post(name: IPCNotification.databaseDidChange, object: nil)
        #if os(macOS)
            try? IPCNotification.post(IPCNotification.databaseDidChange)
        #elseif os(Linux)
            try? postLinuxSignal()
        #endif
    }

    #if os(Linux)
        static func postLinuxSignal(socketPath: String? = nil) throws {
            let resolvedSocketPath: String
            if let socketPath {
                resolvedSocketPath = socketPath
            } else {
                resolvedSocketPath = try TerminalServicePaths.databaseChangeSignalSocketPath()
            }

            let socketFD = socket(AF_UNIX, Self.streamSocketType, 0)
            guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(socketFD) }

            var address = try makeSocketAddress(path: resolvedSocketPath)
            let connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connectResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        private static func makeSocketAddress(path: String) throws -> sockaddr_un {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let maxLength = MemoryLayout.size(ofValue: address.sun_path)
            let utf8Path = path.utf8CString
            guard utf8Path.count <= maxLength else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
                utf8Path.withUnsafeBufferPointer { buffer in if let baseAddress = buffer.baseAddress { memcpy(pointer, baseAddress, buffer.count) } }
            }
            return address
        }

        private static var streamSocketType: Int32 {
            #if canImport(Glibc)
                Int32(SOCK_STREAM.rawValue)
            #else
                SOCK_STREAM
            #endif
        }
    #endif
}

#if os(Linux)
    public final class DatabaseChangeSignalReceiver: @unchecked Sendable {
        private let socketPath: String
        private let queue: DispatchQueue
        private let onSignal: @Sendable () -> Void
        private var acceptSource: DispatchSourceRead?

        public init(socketPath: String? = nil, queue: DispatchQueue, onSignal: @escaping @Sendable () -> Void) throws {
            if let socketPath { self.socketPath = socketPath } else { self.socketPath = try TerminalServicePaths.databaseChangeSignalSocketPath() }
            self.queue = queue
            self.onSignal = onSignal
        }

        public func start() throws {
            try Self.removeSocketFile(at: socketPath)
            let socketFD = socket(AF_UNIX, Self.streamSocketType, 0)
            guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var yes: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
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
            let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptReadySignals(listenSocketFD: socketFD) }
            // The listening descriptor belongs to the dispatch source, not to this object: `stop()` can
            // drop the last reference to this receiver (see the test teardown) while the cancellation it
            // triggers is still pending on `queue`. A cancel handler that reached back through `self`
            // would find it deallocated and never close the descriptor. Capturing `socketFD` by value
            // closes it regardless of whether `self` is still alive.
            //
            // The socket PATH is deliberately not touched here. `start()` already clears a stale path
            // before binding, so a stray file left behind by a delayed cancel is removed there.
            source.setCancelHandler { close(socketFD) }
            acceptSource = source
            source.resume()
        }

        public func stop() {
            queue.async {
                self.acceptSource?.cancel()
                self.acceptSource = nil
            }
        }

        private func acceptReadySignals(listenSocketFD: Int32) {
            while true {
                let clientFD = accept(listenSocketFD, nil, nil)
                if clientFD < 0 {
                    if errno == EWOULDBLOCK || errno == EAGAIN { return }
                    return
                }
                close(clientFD)
                onSignal()
            }
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
                utf8Path.withUnsafeBufferPointer { buffer in if let baseAddress = buffer.baseAddress { memcpy(pointer, baseAddress, buffer.count) } }
            }
            return address
        }

        private static func setNonBlocking(_ fileDescriptor: Int32) throws {
            let currentFlags = fcntl(fileDescriptor, F_GETFL)
            guard currentFlags >= 0, fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        private static var streamSocketType: Int32 {
            #if canImport(Glibc)
                Int32(SOCK_STREAM.rawValue)
            #else
                SOCK_STREAM
            #endif
        }
    }
#endif
