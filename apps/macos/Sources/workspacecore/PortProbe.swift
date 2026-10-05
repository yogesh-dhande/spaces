import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

/// Creates the TCP sockets the port reservation and probe code binds. Close-on-exec is set so a
/// descriptor never survives the daemon's `execv` self-update, where nothing would track it.
enum TCPSocket {
    static func open(family: Int32) -> Int32? {
        #if os(Linux)
            let fd = socket(family, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let fd = socket(family, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }
}

/// Answers whether something on this machine already holds a TCP port, by trying to bind it.
///
/// A port is taken when a bind fails with `EADDRINUSE` on any of 0.0.0.0, 127.0.0.1, `::` or `::1`. The
/// probe sockets set `SO_REUSEADDR` and never `SO_REUSEPORT`:
///
/// - Without `SO_REUSEPORT`, a socket that bound with it (another profile's `PortReserver` placeholder,
///   or a server that opted in) still makes the probe fail, so it counts as taken.
/// - With `SO_REUSEADDR`, a port whose only leftovers are `TIME_WAIT` connections (a server that just
///   stopped) counts as free, so a quick stop-then-start does not report a conflict.
/// - The loopback addresses are probed on their own because, on macOS, `SO_REUSEADDR` lets a wildcard
///   bind succeed beside a listener on a specific address, so the wildcard probe alone would miss a
///   server that listens only on 127.0.0.1 or ::1.
///
/// An address the machine cannot bind at all (`EADDRNOTAVAIL`, `EAFNOSUPPORT`, such as IPv6 disabled)
/// says nothing about the port, so it is skipped rather than counted as taken.
///
/// Accepted gap: on macOS, a server listening only on some other specific address (a LAN IP, or a
/// loopback alias such as 127.0.0.2) passes all four probes. Development servers bind the wildcard or
/// loopback addresses probed here, which is what the probe exists for. Probing every interface address
/// would cost a bind per address per candidate port, to catch a setup that is rare in practice.
enum PortProbe {
    static func isInUse(port: Int) -> Bool {
        guard (1...Int(UInt16.max)).contains(port) else { return false }
        return bindFails(port: port, ipv6: false, loopback: false) || bindFails(port: port, ipv6: false, loopback: true)
            || bindFails(port: port, ipv6: true, loopback: false) || bindFails(port: port, ipv6: true, loopback: true)
    }

    private static func bindFails(port: Int, ipv6: Bool, loopback: Bool) -> Bool {
        guard let fd = TCPSocket.open(family: ipv6 ? AF_INET6 : AF_INET) else { return false }
        defer { close(fd) }
        var reuseAddress: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))
        let result: Int32
        if ipv6 {
            // The IPv4 probes cover IPv4, so this socket must not also claim the v4-mapped space.
            // `Int32(...)`: Glibc imports `IPPROTO_IPV6` from an anonymous enum as `Int`.
            var v6Only: Int32 = 1
            setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(port).bigEndian
            address.sin6_addr = loopback ? in6addr_loopback : in6addr_any
            result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            address.sin_addr.s_addr = loopback ? in_addr_t(INADDR_LOOPBACK).bigEndian : INADDR_ANY
            result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        return result != 0 && errno == EADDRINUSE
    }
}
