import Darwin
import Foundation

/// Talks to `ios_baseline_shaper.py`'s control port to script a dead link for the reconnect scenario:
/// connects over loopback TCP, writes one command line, reads one reply line, and closes. POSIX sockets
/// rather than `NWConnection`: the exchange is one line out, one line back, over 127.0.0.1, so a
/// callback-driven connection state machine buys nothing a blocking socket with a receive timeout does
/// not already give more simply, and this file follows the same direct-socket style already used
/// elsewhere in this codebase for loopback control connections (e.g.
/// `SpacesDeviceServiceTunnelDialer.dialIPv4Loopback` in spacesdeviceapi).
enum ShaperControlClient {
    /// Sends `command` (without a trailing newline; one is appended) to the shaper's control port and
    /// returns its one-line reply (e.g. `"ok down"`), or nil on any connection, send, or receive failure
    /// (including a timeout, via `SO_RCVTIMEO`/`SO_SNDTIMEO`).
    @discardableResult static func send(command: String, port: Int, timeout: TimeInterval = 5) -> String? {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { return nil }
        defer { close(fileDescriptor) }

        var socketTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { return nil }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        let line = command + "\n"
        let sent = line.withCString { cString in Darwin.write(fileDescriptor, cString, strlen(cString)) }
        guard sent > 0 else { return nil }

        // Reads one byte at a time until the reply's trailing newline: the control protocol's replies
        // are a handful of bytes ("ok down\n"), so the simplicity of a byte-at-a-time read outweighs the
        // extra syscalls for this test-only, one-shot exchange.
        var reply = Data()
        while reply.last != 0x0A {
            var byte: UInt8 = 0
            let received = Darwin.read(fileDescriptor, &byte, 1)
            guard received > 0 else { break }
            reply.append(byte)
        }
        guard !reply.isEmpty else { return nil }
        return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
