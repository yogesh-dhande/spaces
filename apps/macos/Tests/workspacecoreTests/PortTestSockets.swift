import Darwin
import Foundation

/// A real TCP socket a test opens on the machine, shaped like one of the holders the port probe has to
/// recognise.
struct TestSocket {
    enum Shape {
        /// 0.0.0.0, like a server listening on every interface.
        case ipv4Any
        case ipv4Loopback
        case ipv6Loopback
        /// 0.0.0.0 with `SO_REUSEPORT` and never listened on, like a `PortReserver` placeholder.
        case placeholder
        /// 0.0.0.0 with `SO_REUSEPORT` and listening, like a server that opted into sharing its port.
        case reusePortListener
    }

    let fd: Int32
    let port: Int

    func close() { Darwin.close(fd) }
}

/// Opens a socket of `shape` on `port` (0 picks a free ephemeral port, reported in the result), or nil when
/// the bind fails. `listening` makes it accept connections.
func openTestSocket(_ shape: TestSocket.Shape, port: Int = 0, listening: Bool = false) -> TestSocket? {
    let ipv6 = shape == .ipv6Loopback
    let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var on: Int32 = 1
    if shape == .placeholder || shape == .reusePortListener {
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
    }
    if ipv6 { setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size)) }
    let bound: Int32
    if ipv6 {
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(port).bigEndian
        address.sin6_addr = in6addr_loopback
        bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
    } else {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = shape == .ipv4Loopback ? in_addr_t(INADDR_LOOPBACK).bigEndian : INADDR_ANY
        bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    }
    guard bound == 0, !listening || listen(fd, 8) == 0, let boundPort = boundPort(of: fd) else {
        Darwin.close(fd)
        return nil
    }
    return TestSocket(fd: fd, port: boundPort)
}

/// `sockaddr_in` and `sockaddr_in6` keep the port at the same offset, so one read covers both.
private func boundPort(of fd: Int32) -> Int? {
    var storage = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let result = withUnsafeMutablePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    guard result == 0 else { return nil }
    return withUnsafePointer(to: &storage) { pointer in
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { Int(UInt16(bigEndian: $0.pointee.sin_port)) }
    }
}
