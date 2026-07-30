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

    /// A restarted local daemon binds a different Device API port, leaving the stored `paired_devices`
    /// port dead. Dialing it must not be the end of the story: this Mac's endpoint is re-resolved
    /// through the local control socket and the resolve retried once, so the caller gets its overview
    /// instead of a timeout. The user-visible symptom otherwise is a terminal window that never opens
    /// after a local daemon restart — the session resolve behind it is this call.
    func testStaleLocalPortReBootstrapsAndResolvesAgainstTheCurrentPort() throws {
        let root = try makeTemporaryRoot()
        let database = try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
        try database.upsert(device: Self.localDevice(port: Self.stalePort))
        let probe = LocalEndpointProbe(livePort: Self.livePort)

        let resolution = try SpacesDeviceClient.resolveOverview(
            device: Self.localDevice(port: Self.stalePort), clientApp: Self.clientApp, profile: Self.profile(root: root),
            requestProvider: probe.requestProvider, database: database, bootstrap: probe.bootstrapProvider)

        XCTAssertEqual(resolution.compatibility, .compatible)
        XCTAssertNotNil(resolution.overview)
        // The resolution carries the refreshed record, so a caller that keeps the device it resolved
        // against (the pane path does) holds the live endpoint rather than the dead one.
        XCTAssertEqual(resolution.overview?.device.port, Self.livePort)
        XCTAssertEqual(probe.dialedPorts, [Self.stalePort, Self.livePort])
        // Retried once, not looped, and the daemon is asked for its endpoint exactly once.
        XCTAssertEqual(probe.bootstrapCount, 1)
        // The refreshed endpoint is persisted, so the next caller starts on the live port.
        XCTAssertEqual(try database.pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID)?.port, Self.livePort)
    }

    func testRemoteDeviceTransportFailureIsNotRecoveredByABootstrap() throws {
        let root = try makeTemporaryRoot()
        let database = try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
        let probe = LocalEndpointProbe(livePort: Self.livePort)

        // A remote device's endpoint is configured, not ephemeral, so an unreachable one is genuinely
        // offline: no local bootstrap can re-resolve it and none is attempted.
        XCTAssertThrowsError(
            try SpacesDeviceClient.resolveOverview(
                device: Self.device, clientApp: Self.clientApp, profile: Self.profile(root: root), requestProvider: probe.requestProvider,
                database: database, bootstrap: probe.bootstrapProvider))
        XCTAssertEqual(probe.bootstrapCount, 0)
        // The wire-compatibility handshake fallback still runs for a remote device.
        XCTAssertEqual(probe.commandNames, ["overview", "daemonStatus"])
    }

    // MARK: - Fixtures

    private static let clientApp = SpacesDeviceClientApp(installationID: "i", bundleID: "b", platform: "macos", deviceName: "Mac", appVersion: "1.0")

    private static let device = SpacesPairedDeviceRecord(
        id: "device-1", name: "Studio Mac", platform: "macos", host: "studio.local", port: 7443, certificateFingerprint: "SHA256:abc",
        createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z", lastSelectedAt: "2026-06-17T00:01:00Z")

    /// The ports from the observed failure: the daemon rebound 47925 while the client's record still
    /// held the previous ephemeral 60839.
    private static let stalePort = 60839
    private static let livePort = 47925

    private static func localDevice(port: Int) -> SpacesPairedDeviceRecord {
        SpacesPairedDeviceRecord(
            id: SpacesPairedDeviceRecord.localDeviceID, name: "This Mac", platform: "macos", host: "127.0.0.1", port: port,
            certificateFingerprint: "SHA256:local", createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z",
            lastSelectedAt: "2026-06-17T00:01:00Z")
    }

    /// Scopes the bootstrap's credential write to the temporary root instead of the developer's profile.
    private static func profile(root: URL) -> SpacesProfile {
        SpacesProfile(
            source: .explicitDatabasePath, databasePath: root.appendingPathComponent("spaces.db").path, rootDirectory: root.path,
            isInstalledProfile: false, runtimeDirectory: root.appendingPathComponent("runtime").path,
            ipcNotificationObject: "spaces.resolve-overview-tests", developmentContext: nil, branchSlug: nil, worktreeHash: nil)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

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

/// Models a daemon that answers on exactly one port: every request to any other port fails the way an
/// unbound port does (`ECONNREFUSED`), and the control-socket bootstrap reports the live one. Records
/// the ports dialed and how many bootstraps ran so a test can assert the recovery retried once.
private final class LocalEndpointProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let livePort: Int
    private var ports: [Int] = []
    private var names: [String] = []
    private var bootstraps = 0

    init(livePort: Int) { self.livePort = livePort }

    var dialedPorts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return ports
    }

    var commandNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    var bootstrapCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bootstraps
    }

    var requestProvider: SpacesDeviceClient.DeviceRequestProvider {
        { request, device, _, _ in
            self.lock.lock()
            self.ports.append(device.port)
            self.names.append(request.command.name)
            let livePort = self.livePort
            self.lock.unlock()
            guard device.port == livePort else { throw POSIXError(.ECONNREFUSED) }
            guard request.command.name == "overview" else { throw POSIXError(.EINVAL) }
            return SpacesDeviceAPIResponse(
                ok: true, message: "ok",
                result: .overview(
                    SpacesDeviceOverviewPayload(
                        workspaces: [], sessions: [],
                        daemonStatus: TerminalServiceDaemonStatus(
                            version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                            protocolVersion: SpacesWireProtocol.version))))
        }
    }

    var bootstrapProvider: SpacesDeviceClient.LocalBootstrapProvider {
        { _, _ in
            self.lock.lock()
            self.bootstraps += 1
            let livePort = self.livePort
            self.lock.unlock()
            return SpacesDeviceAPIControlResponse(
                ok: true, message: "ok",
                result: .localClientBootstrap(
                    SpacesDeviceAPILocalClientBootstrap(
                        deviceID: SpacesPairedDeviceRecord.localDeviceID, name: "This Mac", platform: "macos", host: "127.0.0.1", port: livePort,
                        certificateFingerprint: "SHA256:local", authToken: "TOKEN")))
        }
    }
}
