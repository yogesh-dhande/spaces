import Darwin
import Dispatch
import Foundation

public struct TerminalServiceRequest: Codable, Sendable, Equatable {
    public let command: String
    public let authToken: String?
    public let launchConfiguration: TerminalSessionLaunchConfiguration?
    public let sessionID: String?
    public let runtimeManifest: TerminalServiceWorkspaceRuntimeManifest?
    public let worktreeRefresh: TerminalServiceWorktreeRefreshRequest?
    public let workspaceCommand: TerminalServiceWorkspaceCommandRequest?

    public init(
        command: String, authToken: String? = nil, launchConfiguration: TerminalSessionLaunchConfiguration? = nil, sessionID: String? = nil,
        runtimeManifest: TerminalServiceWorkspaceRuntimeManifest? = nil, worktreeRefresh: TerminalServiceWorktreeRefreshRequest? = nil,
        workspaceCommand: TerminalServiceWorkspaceCommandRequest? = nil
    ) {
        self.command = command
        self.authToken = authToken
        self.launchConfiguration = launchConfiguration
        self.sessionID = sessionID
        self.runtimeManifest = runtimeManifest
        self.worktreeRefresh = worktreeRefresh
        self.workspaceCommand = workspaceCommand
    }

    public func withAuthToken(_ authToken: String?) -> TerminalServiceRequest {
        TerminalServiceRequest(
            command: command, authToken: authToken, launchConfiguration: launchConfiguration, sessionID: sessionID, runtimeManifest: runtimeManifest,
            worktreeRefresh: worktreeRefresh, workspaceCommand: workspaceCommand)
    }
}

public enum TerminalServiceWorkspaceLocation: String, Codable, Sendable, Equatable {
    case local
    case remote
}

public struct TerminalServiceWorkspaceRuntimePortMapping: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let port: Int

    public init(id: String, name: String, port: Int) {
        self.id = id
        self.name = name
        self.port = port
    }
}

public struct TerminalServiceWorkspaceRuntimeManifest: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let projectID: String
    public let computeHostID: String?
    public let location: TerminalServiceWorkspaceLocation
    public let localPath: String
    public let remotePath: String?
    public let branch: String?
    public let targetBranch: String?
    public let gitRemoteURL: String?
    public let namedPorts: [TerminalServiceWorkspaceRuntimePortMapping]
    public let processEnvironment: [String: String]
    public let allowedFileRoots: [String]

    public init(
        workspaceID: String, projectID: String, computeHostID: String?, location: TerminalServiceWorkspaceLocation, localPath: String,
        remotePath: String?, branch: String?, targetBranch: String?, gitRemoteURL: String?, namedPorts: [TerminalServiceWorkspaceRuntimePortMapping],
        processEnvironment: [String: String], allowedFileRoots: [String]
    ) {
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.computeHostID = computeHostID
        self.location = location
        self.localPath = localPath
        self.remotePath = remotePath
        self.branch = branch
        self.targetBranch = targetBranch
        self.gitRemoteURL = gitRemoteURL
        self.namedPorts = namedPorts
        self.processEnvironment = processEnvironment
        self.allowedFileRoots = allowedFileRoots
    }
}

public struct TerminalServiceWorktreeRefreshRequest: Codable, Sendable, Equatable {
    public let path: String
    public let branch: String
    public let hostName: String

    public init(path: String, branch: String, hostName: String) {
        self.path = path
        self.branch = branch
        self.hostName = hostName
    }
}

public struct TerminalServiceWorkspaceCommandRequest: Codable, Sendable, Equatable {
    public let command: String
    public let workingDirectory: String
    public let environment: [String: String]
    public let logPath: String?

    public init(command: String, workingDirectory: String, environment: [String: String] = [:], logPath: String? = nil) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.logPath = logPath
    }
}

public struct TerminalServiceCommandResult: Codable, Sendable, Equatable {
    public let exitCode: Int
    public let logPath: String

    public init(exitCode: Int, logPath: String) {
        self.exitCode = exitCode
        self.logPath = logPath
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
    public let servicePID: Int32?
    public let commandResult: TerminalServiceCommandResult?

    public init(
        ok: Bool, message: String, session: TerminalServiceSessionSummary? = nil, sessions: [TerminalServiceSessionSummary]? = nil,
        servicePID: Int32? = nil, commandResult: TerminalServiceCommandResult? = nil
    ) {
        self.ok = ok
        self.message = message
        self.session = session
        self.sessions = sessions
        self.servicePID = servicePID
        self.commandResult = commandResult
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

    fileprivate static func writeAll(data: Data, to fileDescriptor: Int32) throws {
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

    fileprivate static func readAll(from fileDescriptor: Int32) throws -> Data {
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

    public static func send(request: TerminalServiceRequest, host: String, port: Int, authToken: String? = nil, timeout: TimeInterval = 15) throws
        -> TerminalServiceResponse
    {
        let socketFD = try connectSocket(host: host, port: port)
        defer { close(socketFD) }

        var timeValue = timeval(timeout)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeValue, socklen_t(MemoryLayout<timeval>.size))

        let payload = try TerminalServiceCodec.encodeRequest(request.withAuthToken(authToken ?? request.authToken))
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

    private static func connectSocket(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else { throw POSIXError(.EHOSTUNREACH) }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        var lastErrno: Int32 = EIO
        while let info = current {
            let socketFD = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if socketFD >= 0 {
                if connect(socketFD, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { return socketFD }
                lastErrno = errno
                close(socketFD)
            } else {
                lastErrno = errno
            }
            current = info.pointee.ai_next
        }
        throw POSIXError(POSIXErrorCode(rawValue: lastErrno) ?? .EIO)
    }
}

public final class TerminalServiceTCPServer: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let authToken: String?
    private let queue: DispatchQueue
    private let handleRequest: @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
    private var listenSocketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public private(set) var listeningPort: Int = 0

    public init(
        host: String, port: Int, authToken: String? = nil, queue: DispatchQueue,
        handleRequest: @escaping @Sendable (TerminalServiceRequest) throws -> TerminalServiceResponse
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
                let requestData = try TerminalServiceServer.readAll(from: clientFD)
                let request = try TerminalServiceCodec.decodeRequest(requestData)
                let response = try validateAndHandle(request: request)
                let responseData = try TerminalServiceCodec.encodeResponse(response)
                try TerminalServiceServer.writeAll(data: responseData, to: clientFD)
            } catch {
                let fallback = TerminalServiceResponse(ok: false, message: String(describing: error))
                if let data = try? TerminalServiceCodec.encodeResponse(fallback) { try? TerminalServiceServer.writeAll(data: data, to: clientFD) }
            }

            shutdown(clientFD, SHUT_RDWR)
            close(clientFD)
        }
    }

    private func validateAndHandle(request: TerminalServiceRequest) throws -> TerminalServiceResponse {
        if let authToken, authToken != request.authToken { return TerminalServiceResponse(ok: false, message: "Unauthorized spacesd client.") }
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

extension timeval {
    fileprivate init(_ seconds: TimeInterval) {
        let wholeSeconds = Int(seconds.rounded(.down))
        let microseconds = Int32((seconds - TimeInterval(wholeSeconds)) * 1_000_000)
        self.init(tv_sec: wholeSeconds, tv_usec: microseconds)
    }
}
