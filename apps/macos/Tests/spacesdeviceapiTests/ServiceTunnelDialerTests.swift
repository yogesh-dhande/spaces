import Dispatch
import Foundation
import XCTest

@testable import spacesdeviceapi

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class ServiceTunnelDialerTests: XCTestCase {
    func testDialLoopbackConnectsToIPv6OnlyService() throws {
        let listener = try makeIPv6OnlyLoopbackListener()
        defer {
            close(listener.ipv4GuardFileDescriptor)
            close(listener.fileDescriptor)
        }

        let queue = DispatchQueue(label: "spaces.service-tunnel-dialer.ipv6-test")
        queue.async {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let accepted = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    accept(listener.fileDescriptor, sockaddrPointer, &length)
                }
            }
            guard accepted >= 0 else { return }
            defer { close(accepted) }
            let bytes = [UInt8(ascii: "o"), UInt8(ascii: "k")]
            _ = bytes.withUnsafeBytes { buffer in write(accepted, buffer.baseAddress, buffer.count) }
        }

        let fileDescriptor = try SpacesDeviceServiceTunnelDialer.dialLoopback(port: listener.port, timeoutSeconds: 1, blocking: true)
        defer { close(fileDescriptor) }

        var buffer = [UInt8](repeating: 0, count: 2)
        let count = buffer.withUnsafeMutableBytes { rawBuffer in read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count) }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(String(decoding: buffer, as: UTF8.self), "ok")
    }

    private func makeIPv6OnlyLoopbackListener() throws -> (fileDescriptor: Int32, ipv4GuardFileDescriptor: Int32, port: Int) {
        let listener = socket(AF_INET6, streamSocketType, 0)
        guard listener >= 0 else { throw XCTSkip("IPv6 sockets are unavailable") }
        do {
            var onlyIPv6: Int32 = 1
            guard setsockopt(listener, IPPROTO_IPV6, IPV6_V6ONLY, &onlyIPv6, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = 0
            guard inet_pton(AF_INET6, "::1", &address.sin6_addr) == 1 else { throw XCTSkip("IPv6 loopback is unavailable") }
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    systemBind(listener, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard bindResult == 0 else { throw XCTSkip("IPv6 loopback bind failed: \(errno)") }
            guard listen(listener, 1) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

            var boundAddress = sockaddr_in6()
            var boundLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in getsockname(listener, sockaddrPointer, &boundLength) }
            }
            guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let port = Int(UInt16(bigEndian: boundAddress.sin6_port))
            let ipv4Guard = try bindIPv4Guard(port: port)
            return (listener, ipv4Guard, port)
        } catch {
            close(listener)
            throw error
        }
    }

    private func bindIPv4Guard(port: Int) throws -> Int32 {
        let fileDescriptor = socket(AF_INET, streamSocketType, 0)
        guard fileDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
            guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { throw POSIXError(.EADDRNOTAVAIL) }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    systemBind(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else { throw XCTSkip("IPv4 loopback port \(port) is already in use") }
            return fileDescriptor
        } catch {
            close(fileDescriptor)
            throw error
        }
    }

    private var streamSocketType: Int32 {
        #if canImport(Glibc)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }

    private func systemBind(_ fileDescriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
            Darwin.bind(fileDescriptor, address, length)
        #else
            Glibc.bind(fileDescriptor, address, length)
        #endif
    }
}
