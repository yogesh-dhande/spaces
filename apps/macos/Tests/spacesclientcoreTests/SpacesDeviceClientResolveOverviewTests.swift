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
            context: DeviceRequestContext(
                device: Self.device, clientApp: .init(installationID: "i", bundleID: "b", platform: "macos", deviceName: "Mac", appVersion: "1.0")),
            requestProvider: probe.provider(overviewStatus: Self.status(protocolVersion: SpacesWireProtocol.version)))

        XCTAssertEqual(resolution.compatibility, .compatible)
        XCTAssertNotNil(resolution.overview)
        XCTAssertEqual(resolution.daemonStatus?.protocolVersion, SpacesWireProtocol.version)
        // The whole point: no separate daemonStatus round-trip in the compatible steady state.
        XCTAssertEqual(probe.commandNames, ["overview"])
    }

    func testIncompatibleEmbeddedStatusBlocksWithoutSecondHandshake() throws {
        let probe = RequestProbe()
        let resolution = try SpacesDeviceClient.resolveOverview(
            context: DeviceRequestContext(device: Self.device, clientApp: Self.clientApp),
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
            context: DeviceRequestContext(device: Self.device, clientApp: Self.clientApp),
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
                context: DeviceRequestContext(device: Self.device, clientApp: Self.clientApp),
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
            context: DeviceRequestContext(device: Self.localDevice(port: Self.stalePort), clientApp: Self.clientApp, profile: Self.profile(root: root)),
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

    func testStaleLocalPortRecoveryPersistsTheCurrentRecordWhenTheDaemonIsIncompatible() throws {
        let root = try makeTemporaryRoot()
        let database = try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
        try database.upsert(device: Self.localDevice(port: Self.stalePort))
        let probe = LocalEndpointProbe(livePort: Self.livePort, protocolVersion: SpacesWireProtocol.version + 1)

        let resolution = try SpacesDeviceClient.resolveOverview(
            context: DeviceRequestContext(device: Self.localDevice(port: Self.stalePort), clientApp: Self.clientApp, profile: Self.profile(root: root)),
            requestProvider: probe.requestProvider, database: database, bootstrap: probe.bootstrapProvider)

        XCTAssertEqual(resolution.compatibility, .clientTooOld)
        XCTAssertNil(resolution.overview)
        XCTAssertEqual(probe.bootstrapCount, 1)
        XCTAssertEqual(try database.pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID)?.port, Self.livePort)
    }

    /// The harder case, and the one the ended-session-scroll E2E exercises: the local daemon is not
    /// running at all when the resolve starts, so nothing answers on any port and the request burns its
    /// whole timeout. The recovery has to bring the daemon back — `defaultLocalRecoveryBootstrapProvider`
    /// starts it and waits for its Device API listener — and resolve against the endpoint it came up on.
    /// A recovery that only re-read a stale port would still resolve nothing here.
    func testLocalDaemonDownAtResolveTimeIsStartedByTheRecoveryAndResolves() throws {
        let root = try makeTemporaryRoot()
        let database = try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
        try database.upsert(device: Self.localDevice(port: Self.stalePort))
        // No daemon is listening anywhere: every dial times out, the way the failing E2E run did, rather
        // than being refused by a host with a closed port.
        let probe = LocalEndpointProbe(livePort: Self.livePort, daemonRunning: false)

        let resolution = try SpacesDeviceClient.resolveOverview(
            context: DeviceRequestContext(device: Self.localDevice(port: Self.stalePort), clientApp: Self.clientApp, profile: Self.profile(root: root)),
            requestProvider: probe.requestProvider, database: database, bootstrap: probe.bootstrapProvider)

        XCTAssertEqual(resolution.compatibility, .compatible)
        XCTAssertEqual(resolution.overview?.device.port, Self.livePort)
        // Bounded: the daemon is started once and the overview is retried once against it.
        XCTAssertEqual(probe.bootstrapCount, 1)
        XCTAssertEqual(probe.dialedPorts, [Self.stalePort, Self.livePort])
        XCTAssertEqual(try database.pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID)?.port, Self.livePort)
    }

    func testRevokedLocalTokenReBootstrapsAndRetriesTheOverviewOnce() throws {
        let root = try makeTemporaryRoot()
        let database = try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
        try database.upsert(device: Self.localDevice(port: Self.livePort))
        let probe = LocalEndpointProbe(livePort: Self.livePort)
        probe.rejectsFirstOverviewAsUnauthorized = true

        let resolution = try SpacesDeviceClient.resolveOverview(
            context: DeviceRequestContext(device: Self.localDevice(port: Self.livePort), clientApp: Self.clientApp, profile: Self.profile(root: root)),
            requestProvider: probe.requestProvider, database: database, bootstrap: probe.bootstrapProvider)

        XCTAssertEqual(resolution.compatibility, .compatible)
        XCTAssertEqual(probe.bootstrapCount, 1)
        XCTAssertEqual(
            probe.dialedPorts, [Self.livePort, Self.livePort], "Authorization recovery retries exactly once against the refreshed identity.")
    }

    func testRotatedLocalCertificateOnTheSamePortReBootstrapsAndRetriesWithTheCurrentIdentity() throws {
        let root = try makeTemporaryRoot()
        let database = try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
        let staleDevice = Self.localDevice(port: Self.livePort, certificateFingerprint: "SHA256:stale-local")
        try database.upsert(device: staleDevice)
        let probe = LocalEndpointProbe(livePort: Self.livePort)

        let resolution = try SpacesDeviceClient.resolveOverview(
            context: DeviceRequestContext(device: staleDevice, clientApp: Self.clientApp, profile: Self.profile(root: root)),
            requestProvider: probe.requestProvider, database: database, bootstrap: probe.bootstrapProvider)

        XCTAssertEqual(resolution.compatibility, .compatible)
        XCTAssertEqual(resolution.overview?.device.certificateFingerprint, "SHA256:local")
        XCTAssertEqual(probe.bootstrapCount, 1)
        XCTAssertEqual(probe.dialedPorts, [Self.livePort, Self.livePort], "Identity recovery keeps the daemon's unchanged port.")
        XCTAssertEqual(probe.dialedFingerprints, ["SHA256:stale-local", "SHA256:local"])
        XCTAssertEqual(
            try database.pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID)?.certificateFingerprint, "SHA256:local",
            "The trusted local bootstrap persists the daemon's current identity.")
    }

    /// A recovery that cannot bring the daemon back reports it instead of retrying: the error it surfaces
    /// is the bootstrap's, which `isLocalDaemonUnreachableError` classifies so the local section degrades
    /// to offline rather than showing a failure the user cannot act on.
    func testLocalRecoveryStopsWhenTheDaemonCannotBeStarted() throws {
        let root = try makeTemporaryRoot()
        let database = try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
        let probe = LocalEndpointProbe(livePort: Self.livePort, daemonRunning: false)
        probe.failsBootstrap = true

        XCTAssertThrowsError(
            try SpacesDeviceClient.resolveOverview(
                context: DeviceRequestContext(
                    device: Self.localDevice(port: Self.stalePort), clientApp: Self.clientApp, profile: Self.profile(root: root)),
                requestProvider: probe.requestProvider, database: database, bootstrap: probe.bootstrapProvider)
        ) { error in XCTAssertTrue(SpacesDeviceClient.isLocalDaemonUnreachableError(error)) }
        XCTAssertEqual(probe.bootstrapCount, 1)
        // One failed dial, then the recovery stopped — no second overview attempt against a daemon that
        // could not be started.
        XCTAssertEqual(probe.dialedPorts, [Self.stalePort])
    }

    func testRemoteDeviceTransportFailureIsNotRecoveredByABootstrap() throws {
        let root = try makeTemporaryRoot()
        let database = try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
        let probe = LocalEndpointProbe(livePort: Self.livePort)

        // A remote device's endpoint is configured, not ephemeral, so an unreachable one is genuinely
        // offline: no local bootstrap can re-resolve it and none is attempted.
        XCTAssertThrowsError(
            try SpacesDeviceClient.resolveOverview(
                context: DeviceRequestContext(device: Self.device, clientApp: Self.clientApp, profile: Self.profile(root: root)),
                requestProvider: probe.requestProvider, database: database, bootstrap: probe.bootstrapProvider))
        XCTAssertEqual(probe.bootstrapCount, 0)
        // The wire-compatibility handshake fallback still runs for a remote device.
        XCTAssertEqual(probe.commandNames, ["overview", "daemonStatus"])
    }

    // MARK: - Fixtures

    private static let clientApp = SpacesDeviceClientApp(installationID: "i", bundleID: "b", platform: "macos", deviceName: "Mac", appVersion: "1.0")

    private static let device = SpacesPairedDeviceRecord(
        id: "device-1", name: "Studio Mac", platform: "macos", hosts: ["studio.local"], port: 7443, certificateFingerprint: "SHA256:abc",
        createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z", lastSelectedAt: "2026-06-17T00:01:00Z")

    /// The ports from the observed failure: the daemon rebound 47925 while the client's record still
    /// held the previous ephemeral 60839.
    private static let stalePort = 60839
    private static let livePort = 47925

    private static func localDevice(port: Int, certificateFingerprint: String = "SHA256:local") -> SpacesPairedDeviceRecord {
        SpacesPairedDeviceRecord(
            id: SpacesPairedDeviceRecord.localDeviceID, name: "This Mac", platform: "macos", hosts: ["127.0.0.1"], port: port,
            certificateFingerprint: certificateFingerprint, createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z",
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
        { request, _ in
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

/// Models this Mac's daemon for the recovery paths. A running daemon answers on exactly one port and
/// refuses every other the way an unbound port does; a daemon that is not running answers nothing at all,
/// so every dial times out. The bootstrap stands in for the local control socket: it starts the daemon
/// (`defaultLocalRecoveryBootstrapProvider`'s job) and reports the port it came up on. Records the ports
/// dialed and how many bootstraps ran so a test can assert the recovery stayed bounded.
private final class LocalEndpointProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let livePort: Int
    private let protocolVersion: Int
    private var daemonRunning: Bool
    private var ports: [Int] = []
    private var fingerprints: [String] = []
    private var names: [String] = []
    private var bootstraps = 0

    /// Set to model a daemon that cannot be started at all — the local control socket answers nothing.
    var failsBootstrap = false
    /// Set to model a reachable daemon whose pairing state was reset while the client retained its token.
    var rejectsFirstOverviewAsUnauthorized = false
    private var didRejectOverviewAsUnauthorized = false

    init(livePort: Int, daemonRunning: Bool = true, protocolVersion: Int = SpacesWireProtocol.version) {
        self.livePort = livePort
        self.daemonRunning = daemonRunning
        self.protocolVersion = protocolVersion
    }

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

    var dialedFingerprints: [String] {
        lock.lock()
        defer { lock.unlock() }
        return fingerprints
    }

    var bootstrapCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bootstraps
    }

    var requestProvider: SpacesDeviceClient.DeviceRequestProvider {
        { request, context in
            let device = context.device
            self.lock.lock()
            self.ports.append(device.port)
            self.fingerprints.append(device.certificateFingerprint)
            self.names.append(request.command.name)
            let livePort = self.livePort
            let protocolVersion = self.protocolVersion
            let daemonRunning = self.daemonRunning
            let rejectsAsUnauthorized = self.rejectsFirstOverviewAsUnauthorized && !self.didRejectOverviewAsUnauthorized
            if rejectsAsUnauthorized { self.didRejectOverviewAsUnauthorized = true }
            self.lock.unlock()
            // Nothing is listening, so the dial hangs until the request's own timeout — the shape the
            // failing E2E run recorded (a full 10s spent before the resolve reported nothing).
            guard daemonRunning else { throw POSIXError(.ETIMEDOUT) }
            guard device.port == livePort else { throw POSIXError(.ECONNREFUSED) }
            guard device.certificateFingerprint == "SHA256:local" else {
                throw TerminalServiceTLSError.certificatePinMismatch(expected: device.certificateFingerprint, actual: "SHA256:local")
            }
            guard request.command.name == "overview" else { throw POSIXError(.EINVAL) }
            if rejectsAsUnauthorized { throw SpacesDeviceClientError.requestRejected(message: "Unauthorized", code: .unauthorized) }
            return SpacesDeviceAPIResponse(
                ok: true, message: "ok",
                result: .overview(
                    SpacesDeviceOverviewPayload(
                        workspaces: [], sessions: [],
                        daemonStatus: TerminalServiceDaemonStatus(
                            version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                            protocolVersion: protocolVersion))))
        }
    }

    var bootstrapProvider: SpacesDeviceClient.LocalBootstrapProvider {
        { _, _ in
            self.lock.lock()
            self.bootstraps += 1
            let failsBootstrap = self.failsBootstrap
            // The bootstrap is what starts a daemon that is down, so a successful one leaves it answering.
            if !failsBootstrap { self.daemonRunning = true }
            let livePort = self.livePort
            self.lock.unlock()
            // `ENOENT` on the control socket is how an unstartable local daemon presents: the socket the
            // bootstrap needs is not there. `isLocalDaemonUnreachableError` classifies it as unreachable.
            if failsBootstrap { throw POSIXError(.ENOENT) }
            return SpacesDeviceAPIControlResponse(
                ok: true, message: "ok",
                result: .localClientBootstrap(
                    SpacesDeviceAPILocalClientBootstrap(
                        deviceID: SpacesPairedDeviceRecord.localDeviceID, name: "This Mac", platform: "macos", host: "127.0.0.1", port: livePort,
                        certificateFingerprint: "SHA256:local", authToken: "TOKEN")))
        }
    }
}
