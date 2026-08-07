import Foundation
import XCTest
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui

/// Guards the fix for issue #185: driving a device-backed terminal session's state stream must never
/// block the main actor on the pinned-TLS connect. The connect is gated by a dispatch-semaphore wait,
/// and when it ran on the main actor a stale or unreachable Device API endpoint froze the UI for the
/// full connect timeout (~10s) in repeated bursts. The connect now runs off the main actor, so
/// registering a listener returns to the caller immediately regardless of endpoint reachability.
///
/// A remote device is used deliberately: the local-device path additionally re-resolves the daemon's
/// current port through the control socket, which needs a running daemon and is covered by the
/// `ended-session-scroll` E2E instead. Pointing a remote device at a listener that accepts the TCP
/// handshake but never speaks TLS exercises the exact blocking failure mode from the issue without a
/// daemon: a closed port fails immediately with ECONNREFUSED, so even the pre-fix synchronous connect
/// would return fast enough to pass this test's assertion — the listener must genuinely stall the
/// connect until the pinned-TLS handshake times out.
///
/// XCTest (serial within the class), matching `DeviceTerminalSessionStateModelTranscriptTests`.
@MainActor final class DeviceTerminalSessionStateModelConnectTests: XCTestCase {
    func testRegisteringAListenerAgainstAnUnreachableDeviceReturnsWithoutBlockingTheMainActor() throws {
        // A listener that completes the TCP handshake but never sends a TLS ServerHello: the pinned-TLS
        // connect blocks in the TLS handshake until its ~10s timeout, so on the pre-fix code path
        // `startStateStream` would block the main actor here for the whole connect timeout.
        let stallingListener = try StallingTLSHandshakeListener()
        defer { stallingListener.close() }

        let unreachableDevice = SpacesPairedDeviceRecord(
            id: "remote-unreachable-\(UUID().uuidString)", name: "Remote", platform: "linux", hosts: ["127.0.0.1"], port: stallingListener.port,
            certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64), createdAt: "2026-07-19T00:00:00Z",
            updatedAt: "2026-07-19T00:00:00Z", lastSelectedAt: "2026-07-19T00:00:00Z")
        let model = try DeviceTerminalSessionStateModel(
            device: unreachableDevice, sessionID: "session-\(UUID().uuidString)",
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "session", title: "t", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: "2026-07-19T00:00:00Z",
                workspaceID: "workspace", kind: .shell),
            clientApp: SpacesDeviceClientApp(
                installationID: "INSTALLATION-CONNECT-\(UUID().uuidString)", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID,
                platform: "macos", deviceName: "Mac", appVersion: "1.0"),
            preparedCredentials: .init(certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64), authToken: "token"))

        let startedAt = Date()
        model.startStateStream(onUpdate: { _ in }, onDisconnect: { _ in })
        let elapsed = Date().timeIntervalSince(startedAt)

        // The connect runs off the main actor, so the call returns effectively immediately. The
        // pre-fix synchronous connect blocked for the full ~10s TLS handshake timeout; 3s cleanly
        // separates the two while leaving ample headroom for a loaded CI machine to schedule the
        // background task.
        XCTAssertLessThan(
            elapsed, 3.0, "Registering a listener blocked the main actor for \(elapsed)s — the pinned-TLS connect must run off the main actor")
    }
}

/// A POSIX TCP listener bound to an ephemeral port on 127.0.0.1 that accepts connections into the
/// kernel backlog but never calls `accept()`, so a connecting client's TLS handshake never receives a
/// ServerHello and stalls until it times out. Used to force a genuinely blocking pinned-TLS connect in
/// tests, unlike a closed port (ECONNREFUSED, immediate) or a port that completes a TLS handshake.
private final class StallingTLSHandshakeListener {
    let port: Int
    private let fd: Int32

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var reuseAddress: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0  // Ask the kernel for an ephemeral port.

        let bindResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard listen(socketFD, 1) == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsocknameResult = withUnsafeMutablePointer(to: &boundAddress) { addressPointer -> Int32 in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in getsockname(socketFD, rebound, &boundAddressLength) }
        }
        guard getsocknameResult == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        fd = socketFD
        port = Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    /// Closes the listening socket so a still-stalled background connect from a prior test is reset
    /// quickly instead of dragging out for its full timeout.
    func close() { Darwin.close(fd) }
}
