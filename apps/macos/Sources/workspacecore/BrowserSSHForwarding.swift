import Darwin
import Foundation

struct BrowserSSHForwardRequest: Sendable, Hashable {
    let computeHostID: String
    let displayName: String
    let sshHost: String
    let sshUser: String?
    let sshPort: Int?
    let remotePort: Int
}

enum BrowserSSHForwardResolver {
    typealias Forwarder = @Sendable (BrowserSSHForwardRequest) throws -> Int

    static func resolvedURL(
        _ rawURL: String, runtimePlan: WorkspaceRuntimePlan?, forwarder: Forwarder = { try BrowserSSHForwardManager.shared.localPort(for: $0) }
    ) throws -> String {
        guard let runtimePlan, case .remote(let host) = runtimePlan.selection else { return rawURL }
        guard let components = URLComponents(string: rawURL), isLocalServiceURL(components), let remotePort = components.port else { return rawURL }
        guard runtimePlan.manifest.namedPorts.contains(where: { $0.port == remotePort }) else { return rawURL }
        let localPort = try forwarder(
            BrowserSSHForwardRequest(
                computeHostID: host.id, displayName: host.name, sshHost: host.sshHost, sshUser: normalized(host.sshUser), sshPort: host.sshPort,
                remotePort: remotePort))
        var mapped = components
        mapped.host = "127.0.0.1"
        mapped.port = localPort
        return mapped.string ?? rawURL
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
        let computeHostID: String
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
            computeHostID: request.computeHostID, sshHost: request.sshHost, sshUser: request.sshUser, sshPort: request.sshPort,
            remotePort: request.remotePort)
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

    private func startForward(_ request: BrowserSSHForwardRequest) throws -> Forward {
        let localPort = try Self.allocateEphemeralPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = [
            "-N", "-L", "127.0.0.1:\(localPort):127.0.0.1:\(request.remotePort)", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
        ]
        if let sshPort = request.sshPort { arguments.append(contentsOf: ["-p", String(sshPort)]) }
        arguments.append(sshDestination(request))
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
        let deadline = Date().addingTimeInterval(2)
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
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
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
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
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

    private static func errorText(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.availableData
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty { return text }
        return "ssh exited before the forward was ready."
    }

    private func sshDestination(_ request: BrowserSSHForwardRequest) -> String {
        if let user = request.sshUser { return "\(user)@\(request.sshHost)" }
        return request.sshHost
    }
}
