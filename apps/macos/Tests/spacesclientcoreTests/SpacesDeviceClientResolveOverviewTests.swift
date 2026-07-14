import XCTest
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore

@testable import spacesclientcore

/// Covers the embedded-status refresh path: a compatible device reads its wire-protocol verdict from
/// the overview's inline frozen-core status (one round-trip), and the standalone `daemonStatus`
/// handshake is issued only when the overview itself fails to decode.
final class SpacesDeviceClientResolveOverviewTests: XCTestCase {
    func testCompatibleEmbeddedStatusResolvesWithoutSecondHandshake() throws {
        let probe = RequestProbe()
        let resolution = try SpacesDeviceClient.resolveOverview(
            device: Self.device, clientApp: .init(installationID: "i", bundleID: "b", platform: "macos", deviceName: "Mac", appVersion: "1.0"),
            profile: nil, requestProvider: probe.provider(overviewStatus: Self.status(protocolVersion: SpacesWireProtocol.version)))

        XCTAssertEqual(resolution.compatibility, .compatible)
        XCTAssertNotNil(resolution.overview)
        XCTAssertEqual(resolution.daemonStatus?.protocolVersion, SpacesWireProtocol.version)
        // The whole point: no separate daemonStatus round-trip in the compatible steady state.
        XCTAssertEqual(probe.commandNames, ["overview"])
    }

    func testIncompatibleEmbeddedStatusBlocksWithoutSecondHandshake() throws {
        let probe = RequestProbe()
        let resolution = try SpacesDeviceClient.resolveOverview(
            device: Self.device, clientApp: Self.clientApp, profile: nil,
            requestProvider: probe.provider(overviewStatus: Self.status(protocolVersion: SpacesWireProtocol.version + 1)))

        XCTAssertEqual(resolution.compatibility, .clientTooOld)
        // Blocked: a wire-incompatible device must not surface its (stale) workspace data.
        XCTAssertNil(resolution.overview)
        XCTAssertEqual(probe.commandNames, ["overview"])
    }

    func testUndecodableOverviewFallsBackToHandshakeAndBlocks() throws {
        let probe = RequestProbe()
        // A wire-incompatible daemon's overview cannot decode at all (modeled as a thrown error); the
        // frozen-core handshake stays decodable and reports the incompatibility.
        let resolution = try SpacesDeviceClient.resolveOverview(
            device: Self.device, clientApp: Self.clientApp, profile: nil,
            requestProvider: probe.provider(
                overviewError: POSIXError(.EILSEQ), handshakeStatus: Self.status(protocolVersion: SpacesWireProtocol.version + 1)))

        XCTAssertEqual(resolution.compatibility, .clientTooOld)
        XCTAssertNil(resolution.overview)
        XCTAssertEqual(probe.commandNames, ["overview", "daemonStatus"])
    }

    func testOfflineDeviceRethrowsWhenHandshakeAlsoFails() {
        let probe = RequestProbe()
        XCTAssertThrowsError(
            try SpacesDeviceClient.resolveOverview(
                device: Self.device, clientApp: Self.clientApp, profile: nil,
                requestProvider: probe.provider(overviewError: POSIXError(.ECONNREFUSED), handshakeError: POSIXError(.ECONNREFUSED))))
        XCTAssertEqual(probe.commandNames, ["overview", "daemonStatus"])
    }

    // MARK: - Fixtures

    private static let clientApp = SpacesDeviceClientApp(installationID: "i", bundleID: "b", platform: "macos", deviceName: "Mac", appVersion: "1.0")

    private static let device = SpacesPairedDeviceRecord(
        id: "device-1", name: "Studio Mac", platform: "macos", host: "studio.local", port: 7443, certificateFingerprint: "SHA256:abc",
        createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z", lastSelectedAt: "2026-06-17T00:01:00Z")

    private static func status(protocolVersion: Int) -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: protocolVersion)
    }
}

/// Records the command names a `resolveOverview` call issues so tests can assert how many round-trips
/// it made, and scripts the daemon's overview/handshake responses.
private final class RequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    var commandNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    func provider(
        overviewStatus: TerminalServiceDaemonStatus = TerminalServiceDaemonStatus(
            version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: SpacesWireProtocol.version),
        overviewError: Error? = nil, handshakeStatus: TerminalServiceDaemonStatus? = nil, handshakeError: Error? = nil
    ) -> SpacesDeviceClient.DeviceRequestProvider {
        { request, _, _, _ in
            self.lock.lock()
            self.names.append(request.command.name)
            self.lock.unlock()
            switch request.command.name {
            case "overview":
                if let overviewError { throw overviewError }
                return SpacesDeviceAPIResponse(
                    ok: true, message: "ok",
                    result: .overview(SpacesDeviceOverviewPayload(workspaces: [], sessions: [], daemonStatus: overviewStatus)))
            case "daemonStatus":
                if let handshakeError { throw handshakeError }
                guard let handshakeStatus else { throw POSIXError(.ECONNREFUSED) }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(handshakeStatus))
            default: throw POSIXError(.EINVAL)
            }
        }
    }
}
