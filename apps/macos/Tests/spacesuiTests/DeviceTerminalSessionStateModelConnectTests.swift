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
/// `ended-session-scroll` E2E instead. Pointing a remote device at a closed port exercises the exact
/// blocking failure mode from the issue without a daemon.
///
/// XCTest (serial within the class), matching `DeviceTerminalSessionStateModelTranscriptTests`.
@MainActor final class DeviceTerminalSessionStateModelConnectTests: XCTestCase {
    func testRegisteringAListenerAgainstAnUnreachableDeviceReturnsWithoutBlockingTheMainActor() throws {
        // A never-listening port: the pinned-TLS connect cannot complete, so on the pre-fix code path
        // `startStateStream` would block the main actor here for the whole connect timeout.
        let unreachableDevice = SpacesPairedDeviceRecord(
            id: "remote-unreachable-\(UUID().uuidString)", name: "Remote", platform: "linux", host: "127.0.0.1", port: 1,
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
        // pre-fix synchronous connect blocked for the full ~10s timeout; 3s cleanly separates the two
        // while leaving ample headroom for a loaded CI machine to schedule the background task.
        XCTAssertLessThan(
            elapsed, 3.0, "Registering a listener blocked the main actor for \(elapsed)s — the pinned-TLS connect must run off the main actor")
    }
}
