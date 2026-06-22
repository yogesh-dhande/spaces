import Dispatch
import Foundation
import spacesdevicecore
import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public struct SpacesDeviceAPILocalClientBootstrap: Codable, Equatable, Sendable {
    public let deviceID: String
    public let name: String
    public let platform: String
    public let host: String
    public let port: Int
    public let certificateFingerprint: String
    public let authToken: String
    public let transportKey: String

    public init(
        deviceID: String, name: String, platform: String, host: String, port: Int, certificateFingerprint: String, authToken: String,
        transportKey: String
    ) {
        self.deviceID = deviceID
        self.name = name
        self.platform = platform
        self.host = host
        self.port = port
        self.certificateFingerprint = certificateFingerprint
        self.authToken = authToken
        self.transportKey = transportKey
    }
}

struct SpacesDeviceAPIControlEmptyPayload: Codable, Equatable, Sendable { init() {} }

struct SpacesDeviceAPIControlRevokeDeviceRequest: Codable, Equatable, Sendable {
    let installationID: String

    init(installationID: String) { self.installationID = installationID }
}

struct SpacesDeviceAPIControlBootstrapLocalClientRequest: Codable, Equatable, Sendable {
    let clientApp: SpacesDeviceClientApp

    init(clientApp: SpacesDeviceClientApp) { self.clientApp = clientApp }
}

enum SpacesDeviceAPIControlCommand: Equatable, Sendable {
    case status
    case openPairingWindow
    case listDevices
    case revokeDevice(SpacesDeviceAPIControlRevokeDeviceRequest)
    case resetAllPairings
    case bootstrapLocalClient(SpacesDeviceAPIControlBootstrapLocalClientRequest)

    var name: String {
        switch self {
        case .status: "status"
        case .openPairingWindow: "openPairingWindow"
        case .listDevices: "listDevices"
        case .revokeDevice: "revokeDevice"
        case .resetAllPairings: "resetAllPairings"
        case .bootstrapLocalClient: "bootstrapLocalClient"
        }
    }
}

extension SpacesDeviceAPIControlCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case status
        case openPairingWindow
        case listDevices
        case revokeDevice
        case resetAllPairings
        case bootstrapLocalClient
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "Device API control command must contain exactly one payload."))
        }
        switch key {
        case .status:
            _ = try container.decode(SpacesDeviceAPIControlEmptyPayload.self, forKey: key)
            self = .status
        case .openPairingWindow:
            _ = try container.decode(SpacesDeviceAPIControlEmptyPayload.self, forKey: key)
            self = .openPairingWindow
        case .listDevices:
            _ = try container.decode(SpacesDeviceAPIControlEmptyPayload.self, forKey: key)
            self = .listDevices
        case .revokeDevice: self = .revokeDevice(try container.decode(SpacesDeviceAPIControlRevokeDeviceRequest.self, forKey: key))
        case .resetAllPairings:
            _ = try container.decode(SpacesDeviceAPIControlEmptyPayload.self, forKey: key)
            self = .resetAllPairings
        case .bootstrapLocalClient:
            self = .bootstrapLocalClient(try container.decode(SpacesDeviceAPIControlBootstrapLocalClientRequest.self, forKey: key))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status: try container.encode(SpacesDeviceAPIControlEmptyPayload(), forKey: .status)
        case .openPairingWindow: try container.encode(SpacesDeviceAPIControlEmptyPayload(), forKey: .openPairingWindow)
        case .listDevices: try container.encode(SpacesDeviceAPIControlEmptyPayload(), forKey: .listDevices)
        case .revokeDevice(let payload): try container.encode(payload, forKey: .revokeDevice)
        case .resetAllPairings: try container.encode(SpacesDeviceAPIControlEmptyPayload(), forKey: .resetAllPairings)
        case .bootstrapLocalClient(let payload): try container.encode(payload, forKey: .bootstrapLocalClient)
        }
    }
}

struct SpacesDeviceAPIControlRequest: Codable, Equatable, Sendable {
    let command: SpacesDeviceAPIControlCommand

    init(command: SpacesDeviceAPIControlCommand) { self.command = command }

    var commandName: String { command.name }
}

public struct SpacesDeviceAPIControlStatusResult: Codable, Equatable, Sendable {
    public let status: SpacesDeviceAPIStatus?
    public let pairingWindow: SpacesDevicePairingWindowSnapshot?
    public let devices: [SpacesDevicePairedClient]?

    public init(
        status: SpacesDeviceAPIStatus? = nil, pairingWindow: SpacesDevicePairingWindowSnapshot? = nil, devices: [SpacesDevicePairedClient]? = nil
    ) {
        self.status = status
        self.pairingWindow = pairingWindow
        self.devices = devices
    }
}

public enum SpacesDeviceAPIControlResult: Equatable, Sendable {
    case status(SpacesDeviceAPIControlStatusResult)
    case pairingWindow(SpacesDeviceAPIControlStatusResult)
    case devices([SpacesDevicePairedClient])
    case localClientBootstrap(SpacesDeviceAPILocalClientBootstrap)
}

extension SpacesDeviceAPIControlResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case status
        case pairingWindow
        case devices
        case localClientBootstrap
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Device API control result must contain exactly one payload.")
            )
        }
        switch key {
        case .status: self = .status(try container.decode(SpacesDeviceAPIControlStatusResult.self, forKey: key))
        case .pairingWindow: self = .pairingWindow(try container.decode(SpacesDeviceAPIControlStatusResult.self, forKey: key))
        case .devices: self = .devices(try container.decode([SpacesDevicePairedClient].self, forKey: key))
        case .localClientBootstrap: self = .localClientBootstrap(try container.decode(SpacesDeviceAPILocalClientBootstrap.self, forKey: key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status(let payload): try container.encode(payload, forKey: .status)
        case .pairingWindow(let payload): try container.encode(payload, forKey: .pairingWindow)
        case .devices(let payload): try container.encode(payload, forKey: .devices)
        case .localClientBootstrap(let payload): try container.encode(payload, forKey: .localClientBootstrap)
        }
    }
}

public struct SpacesDeviceAPIControlResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let message: String
    public let result: SpacesDeviceAPIControlResult?

    public init(ok: Bool, message: String, result: SpacesDeviceAPIControlResult? = nil) {
        self.ok = ok
        self.message = message
        self.result = result
    }

    public var status: SpacesDeviceAPIStatus? {
        switch result {
        case .status(let payload), .pairingWindow(let payload): payload.status
        default: nil
        }
    }

    public var pairingWindow: SpacesDevicePairingWindowSnapshot? {
        switch result {
        case .status(let payload), .pairingWindow(let payload): payload.pairingWindow
        default: nil
        }
    }

    public var devices: [SpacesDevicePairedClient]? {
        switch result {
        case .status(let payload), .pairingWindow(let payload): payload.devices
        case .devices(let payload): payload
        default: nil
        }
    }

    public var localClientBootstrap: SpacesDeviceAPILocalClientBootstrap? {
        if case .localClientBootstrap(let payload) = result { payload } else { nil }
    }
}

enum SpacesDeviceAPIControlCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encodeRequest(_ request: SpacesDeviceAPIControlRequest) throws -> Data { try encoder.encode(request) }
    static func decodeRequest(_ data: Data) throws -> SpacesDeviceAPIControlRequest {
        try decoder.decode(SpacesDeviceAPIControlRequest.self, from: data)
    }
    static func encodeResponse(_ response: SpacesDeviceAPIControlResponse) throws -> Data { try encoder.encode(response) }
    static func decodeResponse(_ data: Data) throws -> SpacesDeviceAPIControlResponse {
        try decoder.decode(SpacesDeviceAPIControlResponse.self, from: data)
    }
}

final class SpacesDeviceAPIControlServer {
    private let socketPath: String
    private let queue: DispatchQueue
    private let handleRequest: @Sendable (SpacesDeviceAPIControlRequest) throws -> SpacesDeviceAPIControlResponse
    private var listenSocketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(
        socketPath: String, queue: DispatchQueue,
        handleRequest: @escaping @Sendable (SpacesDeviceAPIControlRequest) throws -> SpacesDeviceAPIControlResponse
    ) {
        self.socketPath = socketPath
        self.queue = queue
        self.handleRequest = handleRequest
    }

    func start() throws {
        try removeSocketIfPresent()
        let socketFD = socket(AF_UNIX, Self.streamSocketType, 0)
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
                let request = try SpacesDeviceAPIControlCodec.decodeRequest(requestData)
                let response = try handleRequest(request)
                let responseData = try SpacesDeviceAPIControlCodec.encodeResponse(response)
                try Self.writeAll(data: responseData, to: clientFD)
            } catch {
                let fallback = SpacesDeviceAPIControlResponse(ok: false, message: String(describing: error))
                if let data = try? SpacesDeviceAPIControlCodec.encodeResponse(fallback) { try? Self.writeAll(data: data, to: clientFD) }
            }

            Self.shutdownSocket(clientFD, how: Self.shutdownReadWrite)
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
            utf8Path.withUnsafeBufferPointer { buffer in if let baseAddress = buffer.baseAddress { memcpy(pointer, baseAddress, buffer.count) } }
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

    private static func shutdownSocket(_ fileDescriptor: Int32, how: Int32) { shutdown(fileDescriptor, how) }

    private static var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }

    private static var shutdownReadWrite: Int32 {
        #if canImport(Glibc)
            Int32(SHUT_RDWR)
        #else
            SHUT_RDWR
        #endif
    }
}

public enum SpacesDeviceAPIControlClient {
    public static func statusEnsuringCurrentTerminalService(timeout: TimeInterval = 5) throws -> SpacesDeviceAPIControlResponse {
        try statusEnsuringCurrentTerminalService(
            timeout: timeout, ensureRunning: { try TerminalService.ensureRunning(timeout: $0) },
            relaunch: { try TerminalService.relaunch(timeout: $0) }, status: { try status(timeout: $0) })
    }

    public static func status(timeout: TimeInterval = 5) throws -> SpacesDeviceAPIControlResponse {
        try send(SpacesDeviceAPIControlRequest(command: .status), timeout: timeout)
    }

    public static func openPairingWindow(timeout: TimeInterval = 5) throws -> SpacesDeviceAPIControlResponse {
        try send(SpacesDeviceAPIControlRequest(command: .openPairingWindow), timeout: timeout)
    }

    public static func openPairingWindowEnsuringCurrentTerminalService(timeout: TimeInterval = 5) throws -> SpacesDeviceAPIControlResponse {
        try responseEnsuringCurrentTerminalService(timeout: timeout, send: { try openPairingWindow(timeout: $0) })
    }

    public static func listDevices(timeout: TimeInterval = 5) throws -> SpacesDeviceAPIControlResponse {
        try send(SpacesDeviceAPIControlRequest(command: .listDevices), timeout: timeout)
    }

    public static func revokeDevice(installationID: String, timeout: TimeInterval = 5) throws -> SpacesDeviceAPIControlResponse {
        try send(SpacesDeviceAPIControlRequest(command: .revokeDevice(.init(installationID: installationID))), timeout: timeout)
    }

    public static func resetAllPairings(timeout: TimeInterval = 5) throws -> SpacesDeviceAPIControlResponse {
        try send(SpacesDeviceAPIControlRequest(command: .resetAllPairings), timeout: timeout)
    }

    public static func bootstrapLocalClient(clientApp: SpacesDeviceClientApp, timeout: TimeInterval = 5) throws -> SpacesDeviceAPIControlResponse {
        try send(SpacesDeviceAPIControlRequest(command: .bootstrapLocalClient(.init(clientApp: clientApp))), timeout: timeout)
    }

    public static func bootstrapLocalClientEnsuringCurrentTerminalService(clientApp: SpacesDeviceClientApp, timeout: TimeInterval = 5) throws
        -> SpacesDeviceAPIControlResponse
    { try responseEnsuringCurrentTerminalService(timeout: timeout, send: { try bootstrapLocalClient(clientApp: clientApp, timeout: $0) }) }

    public static func isControlEndpointUnavailable(_ error: Error) -> Bool {
        if let posixError = error as? POSIXError { return isUnavailablePOSIXCode(posixError.code) }
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain, let code = POSIXErrorCode(rawValue: Int32(nsError.code)) else { return false }
        return isUnavailablePOSIXCode(code)
    }

    static func statusEnsuringCurrentTerminalService(
        timeout: TimeInterval, ensureRunning: (TimeInterval) throws -> Bool, relaunch: (TimeInterval) throws -> Bool,
        status: (TimeInterval) throws -> SpacesDeviceAPIControlResponse,
        hasLiveTerminalSessions: () throws -> Bool = { !((try? TerminalService.listSessions()) ?? []).isEmpty }, retryInterval: TimeInterval = 0.05
    ) throws -> SpacesDeviceAPIControlResponse {
        try responseEnsuringCurrentTerminalService(
            timeout: timeout, ensureRunning: ensureRunning, relaunch: relaunch, send: status, hasLiveTerminalSessions: hasLiveTerminalSessions,
            retryInterval: retryInterval)
    }

    static func responseEnsuringCurrentTerminalService(
        timeout: TimeInterval, ensureRunning: (TimeInterval) throws -> Bool = { try TerminalService.ensureRunning(timeout: $0) },
        relaunch: (TimeInterval) throws -> Bool = { try TerminalService.relaunch(timeout: $0) },
        send: (TimeInterval) throws -> SpacesDeviceAPIControlResponse,
        hasLiveTerminalSessions: () throws -> Bool = { !((try? TerminalService.listSessions()) ?? []).isEmpty }, retryInterval: TimeInterval = 0.05
    ) throws -> SpacesDeviceAPIControlResponse {
        _ = try ensureRunning(timeout)
        var deadline = Date().addingTimeInterval(timeout)
        var lastEndpointError: (any Error)?
        var relaunchedAfterNotRunning = false
        repeat {
            do {
                let response = try send(timeout)
                guard isDeviceAPINotRunningResponse(response), (try? hasLiveTerminalSessions()) != true else { return response }
                if !relaunchedAfterNotRunning {
                    _ = try relaunch(timeout)
                    deadline = Date().addingTimeInterval(timeout)
                    relaunchedAfterNotRunning = true
                }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return response }
                Thread.sleep(forTimeInterval: min(max(retryInterval, 0), remaining))
            } catch {
                guard isControlEndpointUnavailable(error) else { throw error }
                lastEndpointError = error
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                Thread.sleep(forTimeInterval: min(max(retryInterval, 0), remaining))
            }
        } while true

        if (try? hasLiveTerminalSessions()) == true, let lastEndpointError { throw lastEndpointError }
        #if os(Linux)
            if let lastEndpointError { throw lastEndpointError }
        #endif
        _ = try relaunch(timeout)
        return try send(timeout)
    }

    static func isDeviceAPINotRunningResponse(_ response: SpacesDeviceAPIControlResponse) -> Bool {
        !response.ok && response.message == "Device API is not running."
    }

    static func socketPath(fileManager: FileManager = .default) throws -> String {
        let root = try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager)
        let socketRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("spaces-terminal-sockets", isDirectory: true)
        try fileManager.createDirectory(at: socketRoot, withIntermediateDirectories: true)
        return socketRoot.appendingPathComponent("device-api-control-\(socketPathComponent(for: root.path)).sock", isDirectory: false).path
    }

    private static func isUnavailablePOSIXCode(_ code: POSIXErrorCode) -> Bool {
        switch code {
        case .ENOENT, .ECONNREFUSED, .ENOTSOCK: return true
        default: return false
        }
    }

    private static func send(_ request: SpacesDeviceAPIControlRequest, timeout: TimeInterval) throws -> SpacesDeviceAPIControlResponse {
        let socketFD = socket(AF_UNIX, Self.streamSocketType, 0)
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

        let payload = try SpacesDeviceAPIControlCodec.encodeRequest(request)
        try writeAll(data: payload, to: socketFD)
        shutdownSocket(socketFD, how: shutdownWrite)

        let responseData = try readAll(from: socketFD)
        return try SpacesDeviceAPIControlCodec.decodeResponse(responseData)
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

    private static func shutdownSocket(_ fileDescriptor: Int32, how: Int32) {
        #if canImport(Glibc)
            shutdown(fileDescriptor, how)
        #else
            shutdown(fileDescriptor, how)
        #endif
    }

    private static var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }

    private static var shutdownWrite: Int32 {
        #if canImport(Glibc)
            Int32(SHUT_WR)
        #else
            SHUT_WR
        #endif
    }
}

extension timeval {
    fileprivate init(_ seconds: TimeInterval) {
        let wholeSeconds = Int(seconds.rounded(.down))
        #if canImport(Glibc)
            let microseconds = Int((seconds - TimeInterval(wholeSeconds)) * 1_000_000)
        #else
            let microseconds = Int32((seconds - TimeInterval(wholeSeconds)) * 1_000_000)
        #endif
        self.init(tv_sec: wholeSeconds, tv_usec: microseconds)
    }
}
