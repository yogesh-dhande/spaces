import Darwin
import Dispatch
import Foundation
import spacesmobilecore
import spacesterminalcore

public struct SpacesMobileBridgeControlResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let message: String
    public let status: SpacesMobileBridgeStatus?
    public let pairingWindow: SpacesMobilePairingWindowSnapshot?
    public let devices: [SpacesMobilePairedDevice]?

    public init(
        ok: Bool, message: String, status: SpacesMobileBridgeStatus? = nil, pairingWindow: SpacesMobilePairingWindowSnapshot? = nil,
        devices: [SpacesMobilePairedDevice]? = nil
    ) {
        self.ok = ok
        self.message = message
        self.status = status
        self.pairingWindow = pairingWindow
        self.devices = devices
    }
}

struct SpacesMobileBridgeControlRequest: Codable, Equatable, Sendable {
    let command: String
    let installationID: String?
}

enum SpacesMobileBridgeControlCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encodeRequest(_ request: SpacesMobileBridgeControlRequest) throws -> Data { try encoder.encode(request) }
    static func decodeRequest(_ data: Data) throws -> SpacesMobileBridgeControlRequest {
        try decoder.decode(SpacesMobileBridgeControlRequest.self, from: data)
    }
    static func encodeResponse(_ response: SpacesMobileBridgeControlResponse) throws -> Data { try encoder.encode(response) }
    static func decodeResponse(_ data: Data) throws -> SpacesMobileBridgeControlResponse {
        try decoder.decode(SpacesMobileBridgeControlResponse.self, from: data)
    }
}

final class SpacesMobileBridgeControlServer {
    private let socketPath: String
    private let queue: DispatchQueue
    private let handleRequest: @Sendable (SpacesMobileBridgeControlRequest) throws -> SpacesMobileBridgeControlResponse
    private var listenSocketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(
        socketPath: String, queue: DispatchQueue,
        handleRequest: @escaping @Sendable (SpacesMobileBridgeControlRequest) throws -> SpacesMobileBridgeControlResponse
    ) {
        self.socketPath = socketPath
        self.queue = queue
        self.handleRequest = handleRequest
    }

    func start() throws {
        try removeSocketIfPresent()
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

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

    func stop() {
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
                let request = try SpacesMobileBridgeControlCodec.decodeRequest(requestData)
                let response = try handleRequest(request)
                let responseData = try SpacesMobileBridgeControlCodec.encodeResponse(response)
                try Self.writeAll(data: responseData, to: clientFD)
            } catch {
                let fallback = SpacesMobileBridgeControlResponse(ok: false, message: String(describing: error))
                if let data = try? SpacesMobileBridgeControlCodec.encodeResponse(fallback) { try? Self.writeAll(data: data, to: clientFD) }
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

public enum SpacesMobileBridgeControlClient {
    public static func statusEnsuringCurrentTerminalService(timeout: TimeInterval = 5) throws -> SpacesMobileBridgeControlResponse {
        try statusEnsuringCurrentTerminalService(
            timeout: timeout, ensureRunning: { try TerminalService.ensureRunning(timeout: $0) },
            relaunch: { try TerminalService.relaunch(timeout: $0) }, status: { try status(timeout: $0) })
    }

    public static func status(timeout: TimeInterval = 5) throws -> SpacesMobileBridgeControlResponse {
        try send(SpacesMobileBridgeControlRequest(command: "status", installationID: nil), timeout: timeout)
    }

    public static func openPairingWindow(timeout: TimeInterval = 5) throws -> SpacesMobileBridgeControlResponse {
        try send(SpacesMobileBridgeControlRequest(command: "openPairingWindow", installationID: nil), timeout: timeout)
    }

    public static func listDevices(timeout: TimeInterval = 5) throws -> SpacesMobileBridgeControlResponse {
        try send(SpacesMobileBridgeControlRequest(command: "listDevices", installationID: nil), timeout: timeout)
    }

    public static func revokeDevice(installationID: String, timeout: TimeInterval = 5) throws -> SpacesMobileBridgeControlResponse {
        try send(SpacesMobileBridgeControlRequest(command: "revokeDevice", installationID: installationID), timeout: timeout)
    }

    public static func resetAllPairings(timeout: TimeInterval = 5) throws -> SpacesMobileBridgeControlResponse {
        try send(SpacesMobileBridgeControlRequest(command: "resetAllPairings", installationID: nil), timeout: timeout)
    }

    public static func isControlEndpointUnavailable(_ error: Error) -> Bool {
        if let posixError = error as? POSIXError { return isUnavailablePOSIXCode(posixError.code) }
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain, let code = POSIXErrorCode(rawValue: Int32(nsError.code)) else { return false }
        return isUnavailablePOSIXCode(code)
    }

    static func statusEnsuringCurrentTerminalService(
        timeout: TimeInterval, ensureRunning: (TimeInterval) throws -> Bool, relaunch: (TimeInterval) throws -> Bool,
        status: (TimeInterval) throws -> SpacesMobileBridgeControlResponse,
        hasLiveTerminalSessions: () throws -> Bool = { !((try? TerminalService.listSessions()) ?? []).isEmpty }
    ) throws -> SpacesMobileBridgeControlResponse {
        _ = try ensureRunning(timeout)
        do { return try status(timeout) } catch {
            guard isControlEndpointUnavailable(error) else { throw error }
            if (try? hasLiveTerminalSessions()) == true { throw error }
            _ = try relaunch(timeout)
            return try status(timeout)
        }
    }

    static func socketPath(fileManager: FileManager = .default) throws -> String {
        let root = try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager)
        let socketRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("spaces-terminal-sockets", isDirectory: true)
        try fileManager.createDirectory(at: socketRoot, withIntermediateDirectories: true)
        return socketRoot.appendingPathComponent("mobile-control-\(socketPathComponent(for: root.path)).sock", isDirectory: false).path
    }

    private static func isUnavailablePOSIXCode(_ code: POSIXErrorCode) -> Bool {
        switch code {
        case .ENOENT, .ECONNREFUSED, .ENOTSOCK: return true
        default: return false
        }
    }

    private static func send(_ request: SpacesMobileBridgeControlRequest, timeout: TimeInterval) throws -> SpacesMobileBridgeControlResponse {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(socketFD) }

        var address = try makeSocketAddress(path: socketPath())
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var timeValue = timeval(timeout)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))

        let payload = try SpacesMobileBridgeControlCodec.encodeRequest(request)
        try writeAll(data: payload, to: socketFD)
        shutdown(socketFD, SHUT_WR)

        let responseData = try readAll(from: socketFD)
        return try SpacesMobileBridgeControlCodec.decodeResponse(responseData)
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

    private static func socketPathComponent(for rootPath: String) -> String {
        var hash: UInt64 = 5381
        for byte in rootPath.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(byte) }
        return String(format: "%016llx", hash)
    }
}

extension timeval {
    fileprivate init(_ seconds: TimeInterval) {
        let wholeSeconds = Int(seconds.rounded(.down))
        let microseconds = Int32((seconds - TimeInterval(wholeSeconds)) * 1_000_000)
        self.init(tv_sec: wholeSeconds, tv_usec: microseconds)
    }
}
