import Darwin
import Foundation

public final class PortReserver: Sendable {
    public static let shared = PortReserver()

    private let lock = NSLock()
    private nonisolated(unsafe) let _reservedSockets = UnsafeMutablePointer<[String: [Int32]]>.allocate(capacity: 1)

    private init() { _reservedSockets.initialize(to: [:]) }

    deinit {
        lock.lock()
        let all = _reservedSockets.pointee
        lock.unlock()
        for (_, fds) in all { for fd in fds { Darwin.close(fd) } }
        _reservedSockets.deinitialize(count: 1)
        _reservedSockets.deallocate()
    }

    public func reservePorts(workspaceID: String, ports: [Int]) {
        var fds: [Int32] = []
        for port in ports { if let fd = bindSocket(port: port) { fds.append(fd) } }
        lock.lock()
        if let existing = _reservedSockets.pointee[workspaceID] { for fd in existing { Darwin.close(fd) } }
        _reservedSockets.pointee[workspaceID] = fds
        lock.unlock()
    }

    public func releasePorts(workspaceID: String) {
        lock.lock()
        if let fds = _reservedSockets.pointee.removeValue(forKey: workspaceID) {
            lock.unlock()
            for fd in fds { Darwin.close(fd) }
        } else {
            lock.unlock()
        }
    }

    public func reservedWorkspaceIDs() -> Set<String> {
        lock.lock()
        let ids = Set(_reservedSockets.pointee.keys)
        lock.unlock()
        return ids
    }

    private func bindSocket(port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &opt, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            Darwin.close(fd)
            return nil
        }
        return fd
    }
}
