import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

struct BrowserSSHForwardRequest: Sendable, Hashable {
    let deviceID: String
    let displayName: String
    let sshHost: String
    let sshUser: String?
    let sshPort: Int?
    let remotePort: Int
}

enum BrowserSSHForwardResolver {
    typealias Forwarder = @Sendable (BrowserSSHForwardRequest) throws -> Int
    typealias LiveForwardChecker = @Sendable (Int, BrowserSSHForwardRequest) -> Bool

    static func resolvedURL(
        _ rawURL: String, runtimePlan: WorkspaceRuntimePlan?, forwarder: Forwarder = { try BrowserSSHForwardManager.shared.localPort(for: $0) }
    ) throws -> String {
        guard let (components, request) = forwardRequest(rawURL: rawURL, runtimePlan: runtimePlan) else { return rawURL }
        let localPort = try forwarder(request)
        var mapped = components
        mapped.host = "127.0.0.1"
        mapped.port = localPort
        return mapped.string ?? rawURL
    }

    static func reusableResolvedURL(
        _ candidateURL: String?, for rawURL: String, runtimePlan: WorkspaceRuntimePlan?,
        liveForwardChecker: LiveForwardChecker = { BrowserSSHForwardManager.shared.hasLiveForward(localPort: $0, for: $1) }
    ) -> String? {
        guard let candidateURL, let (components, request) = forwardRequest(rawURL: rawURL, runtimePlan: runtimePlan) else { return nil }
        guard var candidate = URLComponents(string: candidateURL), isLocalServiceURL(candidate), let localPort = candidate.port else { return nil }
        guard candidate.scheme?.lowercased() == components.scheme?.lowercased() else { return nil }
        guard candidate.percentEncodedPath == components.percentEncodedPath else { return nil }
        guard candidate.percentEncodedQuery == components.percentEncodedQuery else { return nil }
        guard liveForwardChecker(localPort, request) else { return nil }
        candidate.host = "127.0.0.1"
        candidate.port = localPort
        return candidate.string
    }

    private static func forwardRequest(rawURL: String, runtimePlan: WorkspaceRuntimePlan?) -> (URLComponents, BrowserSSHForwardRequest)? {
        guard let runtimePlan, case .remote(let device) = runtimePlan.selection else { return nil }
        guard let components = URLComponents(string: rawURL), isLocalServiceURL(components), let remotePort = components.port else { return nil }
        guard runtimePlan.manifest.namedPorts.contains(where: { $0.port == remotePort }) else { return nil }
        return (
            components,
            BrowserSSHForwardRequest(
                deviceID: device.id, displayName: device.name, sshHost: device.sshHost, sshUser: normalized(device.sshUser), sshPort: device.sshPort,
                remotePort: remotePort)
        )
    }

    private static func isLocalServiceURL(_ components: URLComponents) -> Bool {
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

final class BrowserSSHForwardManager: @unchecked Sendable {
    static let shared = BrowserSSHForwardManager()

    private struct ForwardKey: Hashable {
        let deviceID: String
        let sshHost: String
        let sshUser: String?
        let sshPort: Int?
        let remotePort: Int
    }

    private struct Forward {
        let localPort: Int
        let process: Process
    }

    private let lock = NSLock()
    private var forwards: [ForwardKey: Forward] = [:]

    func localPort(for request: BrowserSSHForwardRequest) throws -> Int {
        let key = ForwardKey(
            deviceID: request.deviceID, sshHost: request.sshHost, sshUser: request.sshUser, sshPort: request.sshPort, remotePort: request.remotePort)
        lock.lock()
        if let existing = forwards[key], existing.process.isRunning {
            let localPort = existing.localPort
            lock.unlock()
            return localPort
        }
        forwards[key] = nil
        lock.unlock()

        let forward = try startForward(request)
        lock.lock()
        forwards[key] = forward
        lock.unlock()
        return forward.localPort
    }

    func hasLiveForward(localPort: Int, for request: BrowserSSHForwardRequest) -> Bool {
        let key = ForwardKey(
            deviceID: request.deviceID, sshHost: request.sshHost, sshUser: request.sshUser, sshPort: request.sshPort, remotePort: request.remotePort)
        lock.lock()
        if let existing = forwards[key], existing.localPort == localPort, existing.process.isRunning {
            lock.unlock()
            return true
        }
        lock.unlock()
        return Self.hasLiveSSHForward(localPort: localPort, request: request)
    }

    private func startForward(_ request: BrowserSSHForwardRequest) throws -> Forward {
        let localPort = try Self.allocateEphemeralPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = [
            "-N", "-L", "127.0.0.1:\(localPort):127.0.0.1:\(request.remotePort)", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
        ]
        if let sshPort = request.sshPort { arguments.append(contentsOf: ["-p", String(sshPort)]) }
        arguments.append(Self.sshDestination(request))
        process.arguments = arguments
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        do { try waitForForward(process: process, port: localPort, standardError: standardError, displayName: request.displayName) } catch {
            process.terminate()
            throw error
        }
        return Forward(localPort: localPort, process: process)
    }

    private func waitForForward(process: Process, port: Int, standardError: Pipe, displayName: String) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !process.isRunning {
                throw WorkspaceError.invalidArgument(
                    message: "Could not open browser SSH forward for \(displayName): \(Self.errorText(from: standardError))")
            }
            if Self.canConnectToLocalhost(port: port) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw WorkspaceError.invalidArgument(message: "Timed out opening browser SSH forward for \(displayName) on localhost:\(port).")
    }

    private static func allocateEphemeralPort() throws -> Int {
        #if os(Linux)
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if !os(Linux)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in getsockname(fd, sockaddrPointer, &length) }
        }
        guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private static func canConnectToLocalhost(port: Int) -> Bool {
        #if os(Linux)
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        #if !os(Linux)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func hasLiveSSHForward(localPort: Int, request: BrowserSSHForwardRequest) -> Bool {
        guard canConnectToLocalhost(port: localPort) else { return false }
        let forwardArgument = "127.0.0.1:\(localPort):127.0.0.1:\(request.remotePort)"
        let destination = sshDestination(request)
        return runningProcessCommandLines().contains { line in
            guard line.contains("ssh"), line.contains("-N"), line.contains(forwardArgument), line.contains(destination) else { return false }
            guard let sshPort = request.sshPort else { return true }
            return line.contains("-p \(sshPort)") || line.contains("-p\(sshPort)")
        }
    }

    private static func runningProcessCommandLines() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").map(String.init)
        } catch { return [] }
    }

    private static func errorText(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.availableData
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty { return text }
        return "ssh exited before the forward was ready."
    }

    private static func sshDestination(_ request: BrowserSSHForwardRequest) -> String {
        if let user = request.sshUser { return "\(user)@\(request.sshHost)" }
        return request.sshHost
    }
}
