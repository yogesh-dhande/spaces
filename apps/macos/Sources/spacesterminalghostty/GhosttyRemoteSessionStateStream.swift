import Dispatch
import Foundation
import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class GhosttyRemoteSessionStateStreamServer: @unchecked Sendable {
    fileprivate static let ioBufferSize = 256 * 1024
    private static let socketBufferSize: Int32 = 1024 * 1024
    private static let writeRetrySleepInterval: TimeInterval = 0.0005

    private let socketPath: String
    private let queue: DispatchQueue
    private let initialStateProvider: @Sendable () -> GhosttyRemoteSessionStatePayload?
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]

    init(socketPath: String, queue: DispatchQueue, initialStateProvider: @escaping @Sendable () -> GhosttyRemoteSessionStatePayload?) {
        self.socketPath = socketPath
        self.queue = queue
        self.initialStateProvider = initialStateProvider
    }

    func start() throws {
        try removeSocketIfPresent()
        let socketFD = socket(AF_UNIX, Self.streamSocketType, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        try Self.setNoSIGPIPE(socketFD)

        var address = try Self.makeSocketAddress(path: socketPath)
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
        try Self.setNonBlocking(socketFD)

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptReadyConnections(listenSocketFD: socketFD) }
        // The listening descriptor belongs to the dispatch source, not to this object: every caller
        // stops a server and drops its last reference in the same breath, so a cancel handler that
        // reached back through `self` would find it deallocated and never close the descriptor —
        // leaking one per session for the daemon's lifetime. Dispatch runs this handler after every
        // pending event handler on `queue`, so the captured descriptor stays valid for each accept
        // and is closed exactly once here.
        //
        // The socket PATH is deliberately not touched here; removing it is the caller's job, which
        // every stop site already does inline. This handler runs asynchronously on `queue`, so a caller
        // that stops a server and immediately rebinds the same path (the resume-in-place path after a
        // failed exec) could otherwise have this stale handler unlink the *new* server's socket file,
        // leaving it bound to a path no client can reach.
        source.setCancelHandler { close(socketFD) }
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

    func broadcast(_ payload: GhosttyRemoteSessionStatePayload) {
        queue.async {
            guard !self.clientSources.isEmpty else { return }
            guard let data = try? GhosttyRemoteSessionStateCodec.encodeLine(payload) else { return }
            for fd in Array(self.clientSources.keys) where !Self.writeAll(data: data, to: fd) { self.closeClient(fd) }
        }
    }

    private func acceptReadyConnections(listenSocketFD: Int32) {
        while true {
            let clientFD = accept(listenSocketFD, nil, nil)
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { return }
                return
            }

            do {
                try Self.setNoSIGPIPE(clientFD)
                Self.applySocketBuffers(clientFD)
                try Self.setNonBlocking(clientFD)
                Self.applySocketTimeouts(clientFD)
                let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
                source.setEventHandler { [weak self] in self?.drainClientInput(clientFD) }
                source.setCancelHandler { close(clientFD) }
                clientSources[clientFD] = source
                source.resume()
                if let payload = initialStateProvider(), let data = try? GhosttyRemoteSessionStateCodec.encodeLine(payload) {
                    if !Self.writeAll(data: data, to: clientFD) { closeClient(clientFD) }
                }
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

    private func removeSocketIfPresent() throws { try Self.removeSocketFile(at: socketPath) }

    static func removeSocketFileIfPresent(at path: String) { try? removeSocketFile(at: path) }

    private static func removeSocketFile(at path: String) throws {
        let result = path.withCString { unlink($0) }
        guard result != 0 else { return }
        if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    fileprivate static func makeSocketAddress(path: String) throws -> sockaddr_un {
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

    fileprivate static func setNonBlocking(_ fileDescriptor: Int32) throws {
        let currentFlags = fcntl(fileDescriptor, F_GETFL)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fileDescriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    fileprivate static func setNoSIGPIPE(_ fileDescriptor: Int32) throws {
        #if canImport(Darwin)
            var yes: Int32 = 1
            guard setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        #else
            _ = fileDescriptor
        #endif
    }

    private static func applySocketTimeouts(_ fileDescriptor: Int32) {
        var timeValue = timeval(seconds: 0.2)
        setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))
    }

    fileprivate static func applySocketBuffers(_ fileDescriptor: Int32) {
        var bufferSize = socketBufferSize
        setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
    }

    fileprivate static func writeAll(data: Data, to fileDescriptor: Int32) -> Bool {
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

    fileprivate static var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }
}

/// One connection's partial-line accumulator, held by reference so the read source's event handler can
/// own it.
///
/// Ownership is the point: the drain runs on the client's private serial queue while `stop()` runs on
/// whatever thread tore the session down, so a buffer reachable from both is an unsynchronized mutation
/// of non-`Sendable` `Data` — a teardown landing mid-drain emptied the buffer under a live index and
/// trapped the process. Living inside the handler closure makes that unrepresentable: only the queue can
/// reach it, and cancelling the source releases it instead of anyone clearing it from outside.
private final class GhosttyRemoteSessionStateReadBuffer { var lines = LineFrameBuffer() }

final class GhosttyRemoteSessionStateStreamClient: @unchecked Sendable {
    private let socketPath: String
    private let onEvent: @MainActor @Sendable (GhosttyRemoteSessionStatePayload) -> Void
    private let onDisconnect: @MainActor @Sendable () -> Void
    private let queue: DispatchQueue
    private let eventLock = NSLock()
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var pendingEvents: [GhosttyRemoteSessionStatePayload] = []
    private var eventDeliveryScheduled = false

    init(
        socketPath: String, onEvent: @escaping @MainActor @Sendable (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.socketPath = socketPath
        self.onEvent = onEvent
        self.onDisconnect = onDisconnect
        queue = DispatchQueue(label: "spaces.terminal.remote-session-state.\(UUID().uuidString)")
    }

    var isConnected: Bool { socketFD >= 0 }

    func start() throws {
        guard socketFD < 0 else { return }
        let socketFD = socket(AF_UNIX, GhosttyRemoteSessionStateStreamServer.streamSocketType, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try GhosttyRemoteSessionStateStreamServer.setNoSIGPIPE(socketFD)
        GhosttyRemoteSessionStateStreamServer.applySocketBuffers(socketFD)

        var address = try GhosttyRemoteSessionStateStreamServer.makeSocketAddress(path: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            close(socketFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try GhosttyRemoteSessionStateStreamServer.setNonBlocking(socketFD)
        self.socketFD = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        // The descriptor and the read buffer are handed to the handler rather than read back off the
        // client, so the drain touches nothing the stopping thread can mutate underneath it. The
        // descriptor stays valid for every handler invocation because dispatch runs the cancel handler
        // that closes it after all pending event handlers on this serial queue.
        let readBuffer = GhosttyRemoteSessionStateReadBuffer()
        source.setEventHandler { [weak self] in self?.readAvailableEvents(socketFD: socketFD, readBuffer: readBuffer) }
        source.setCancelHandler { close(socketFD) }
        readSource = source
        source.resume()
    }

    func stop() {
        guard socketFD >= 0 else { return }
        let source = readSource
        readSource = nil
        let socketFD = self.socketFD
        self.socketFD = -1
        eventLock.lock()
        pendingEvents.removeAll(keepingCapacity: false)
        eventDeliveryScheduled = false
        eventLock.unlock()
        source?.cancel()
        Self.shutdownSocket(socketFD)
        Task { @MainActor [onDisconnect] in onDisconnect() }
    }

    /// Runs only on `queue`. `stop()` unblocks and cancels the source rather than reaching in here, so a
    /// teardown concurrent with a drain shuts the socket down (further reads return 0) and lets this
    /// invocation finish against state nobody else can touch.
    private func readAvailableEvents(socketFD: Int32, readBuffer: GhosttyRemoteSessionStateReadBuffer) {
        var buffer = [UInt8](repeating: 0, count: GhosttyRemoteSessionStateStreamServer.ioBufferSize)
        while true {
            let count = read(socketFD, &buffer, buffer.count)
            if count == 0 {
                Task { @MainActor [weak self] in self?.stop() }
                return
            }
            if count < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { break }
                Task { @MainActor [weak self] in self?.stop() }
                return
            }
            readBuffer.lines.append(Data(buffer[..<count]))
        }

        while let line = readBuffer.lines.popLine() {
            guard !line.isEmpty, let payload = try? GhosttyRemoteSessionStateCodec.decodeLine(line) else { continue }
            enqueueEvent(payload)
        }
    }

    private func enqueueEvent(_ payload: GhosttyRemoteSessionStatePayload) {
        eventLock.lock()
        if let pendingIndex = pendingEvents.indices.last, Self.canCoalescePendingEvent(pendingEvents[pendingIndex], with: payload) {
            pendingEvents[pendingIndex] = pendingEvents[pendingIndex].merged(with: payload)
        } else {
            pendingEvents.append(payload)
        }
        guard !eventDeliveryScheduled else {
            eventLock.unlock()
            return
        }
        eventDeliveryScheduled = true
        eventLock.unlock()
        Task { @MainActor [weak self] in
            guard let self else { return }
            while let payload = self.takePendingEvent() {
                self.onEvent(payload)
                await Task.yield()
            }
        }
    }

    private func takePendingEvent() -> GhosttyRemoteSessionStatePayload? {
        eventLock.lock()
        defer { eventLock.unlock() }
        guard !pendingEvents.isEmpty else {
            eventDeliveryScheduled = false
            return nil
        }
        return pendingEvents.removeFirst()
    }

    static func canCoalescePendingEvent(_ pending: GhosttyRemoteSessionStatePayload, with update: GhosttyRemoteSessionStatePayload) -> Bool {
        guard pending.sessionID == update.sessionID, pending.reason == update.reason else { return false }
        guard !containsDeltaRenderUpdate(pending), !containsDeltaRenderUpdate(update) else { return false }
        switch update.reason {
        case TerminalRemoteSessionStateReason.initial, TerminalRemoteSessionStateReason.runtimeState, TerminalRemoteSessionStateReason.resize,
            TerminalRemoteSessionStateReason.stateChange:
            return true
        default: return false
        }
    }

    private static func containsDeltaRenderUpdate(_ payload: GhosttyRemoteSessionStatePayload) -> Bool { payload.decodedRenderUpdate?.kind == .delta }

    private static func shutdownSocket(_ fileDescriptor: Int32) {
        #if canImport(Darwin)
            shutdown(fileDescriptor, SHUT_RDWR)
        #else
            shutdown(fileDescriptor, Int32(SHUT_RDWR))
        #endif
    }
}

extension timeval {
    fileprivate init(seconds: TimeInterval) {
        let wholeSeconds = Int(seconds.rounded(.down))
        #if canImport(Glibc)
            let microseconds = Int((seconds - TimeInterval(wholeSeconds)) * 1_000_000)
        #else
            let microseconds = Int32((seconds - TimeInterval(wholeSeconds)) * 1_000_000)
        #endif
        self.init(tv_sec: wholeSeconds, tv_usec: microseconds)
    }
}
