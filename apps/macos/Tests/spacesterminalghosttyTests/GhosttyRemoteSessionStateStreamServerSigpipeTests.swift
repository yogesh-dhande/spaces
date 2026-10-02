import Dispatch
import Foundation
import Testing
import spacesterminalcore

@testable import spacesterminalghostty

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// A subscriber that closes its end while a broadcast is already queued must cost the server only that
/// subscriber. On Linux a plain `write` to a closed stream socket raises SIGPIPE, which kills any host
/// process that has not ignored the signal (`spacesd` ignores it; this test runner does not), so a
/// regression fails here by terminating the whole run rather than by an assertion. The surviving
/// subscriber receiving the broadcast shows the server wrote past the closed peer and kept serving.
@Suite(.serialized) struct GhosttyRemoteSessionStateStreamServerSigpipeTests {
    @Test func broadcastPastAClosedSubscriberStillReachesTheOthers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("s.sock").path
        let queue = DispatchQueue(label: "stream-sigpipe-test")
        let server = GhosttyRemoteSessionStateStreamServer(socketPath: socketPath, queue: queue) { Self.payload(title: "initial-marker") }
        try server.start()
        defer { server.stop() }

        // Each subscriber's first line proves the server accepted it.
        let closing = try Self.dial(socketPath)
        var closingOpen = true
        defer { if closingOpen { close(closing) } }
        _ = try Self.readLine(closing)
        let surviving = try Self.dial(socketPath)
        defer { close(surviving) }
        _ = try Self.readLine(surviving)

        // Hold the server's queue so the broadcast is queued ahead of the read source's EOF handler, which
        // would otherwise drop the subscriber before the write ever reaches a closed peer.
        let release = DispatchSemaphore(value: 0)
        queue.async { release.wait() }
        server.broadcast(Self.payload(title: "broadcast-marker"))
        close(closing)
        closingOpen = false
        release.signal()

        #expect(try Self.readLine(surviving).contains("broadcast-marker"))
    }

    private static func dial(_ socketPath: String) throws -> Int32 {
        #if canImport(Glibc)
            let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        try withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard pathBytes.count < raw.count else { throw POSIXError(.ENAMETOOLONG) }
            raw.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        // A read that has not completed in this long fails the test instead of hanging it.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Reads one newline-terminated line, one byte at a time so nothing past it is consumed.
    private static func readLine(_ fd: Int32) throws -> String {
        var line = [UInt8]()
        var byte: UInt8 = 0
        while true {
            guard read(fd, &byte, 1) == 1 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if byte == 0x0A { return String(decoding: line, as: UTF8.self) }
            line.append(byte)
        }
    }

    private static func payload(title: String) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: "s", reason: "initial", emittedAt: "2026-01-01T00:00:00Z", sessionStateRevision: nil, sessionStateFlags: nil,
            screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: title, workingDirectory: "/", outputByteCount: nil)
    }
}
