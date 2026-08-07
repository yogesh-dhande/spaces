import XCTest
import spacesdevicecore
import spacesterminalcore

@testable import spacesclientcore

/// Covers what a delivered overview teaches the client about where a device can be reached: the daemon
/// reports its own current addresses on every overview, and folding them in is how a device paired
/// before its Mac ever had Tailscale gains the tailnet fallback without being re-paired.
final class SpacesDeviceAdvertisedHostMergeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SpacesDeviceEndpointRegistry.resetForTesting()
    }

    override func tearDown() {
        SpacesDeviceEndpointRegistry.resetForTesting()
        super.tearDown()
    }

    func testOverviewWidensTheStoredCandidatesAndTheLiveResolver() throws {
        let database = try makeDatabase()
        try database.upsert(device: Self.device)
        let resolver = SpacesDeviceEndpointRegistry.resolver(for: Self.device, certificateFingerprint: Self.device.certificateFingerprint)
        XCTAssertEqual(resolver.candidateHosts, ["studio.local"])

        let resolution = try SpacesDeviceClient.resolveOverview(
            device: Self.device, clientApp: Self.clientApp, profile: nil,
            requestProvider: Self.requestProvider(advertised: ["192.168.1.50", "100.64.0.1"]), database: database)

        XCTAssertNotNil(resolution.overview)
        // The daemon's own list leads (it is authoritative about preference: LAN before tailnet), with
        // the previously stored address kept behind it.
        XCTAssertEqual(try database.pairedDevice(id: Self.device.id)?.hosts, ["192.168.1.50", "100.64.0.1", "studio.local"])
        // The shared resolver picks the widening up immediately: the newly learned address is dialable
        // now, not after the next relaunch.
        XCTAssertEqual(resolver.candidateHosts, ["192.168.1.50", "100.64.0.1", "studio.local"])
    }

    /// The learned address has to survive the caller holding on to what the overview handed back.
    ///
    /// The client passes a record in, the merge widens the stored candidates, and the caller then keeps
    /// the record from the resolution and passes it to `resolver(for:)` on its next action. If the
    /// resolution still carried the pre-merge record, that lookup's reconcile would hand the resolver the
    /// narrower list and strip the just-learned address back out — the widening would survive in the
    /// database and be undone in memory on the very next request.
    func testTheRecordTheOverviewPublishesKeepsTheLearnedAddressThroughALaterResolverLookup() throws {
        let database = try makeDatabase()
        try database.upsert(device: Self.device)
        let resolver = SpacesDeviceEndpointRegistry.resolver(for: Self.device, certificateFingerprint: Self.device.certificateFingerprint)

        let resolution = try SpacesDeviceClient.resolveOverview(
            device: Self.device, clientApp: Self.clientApp, profile: nil,
            requestProvider: Self.requestProvider(advertised: ["192.168.1.50", "100.64.0.1"]), database: database)

        let published = try XCTUnwrap(resolution.overview?.device)
        XCTAssertEqual(published.hosts, ["192.168.1.50", "100.64.0.1", "studio.local"])

        // What the caller now holds is what it dials with next.
        let reused = SpacesDeviceEndpointRegistry.resolver(for: published, certificateFingerprint: published.certificateFingerprint)

        XCTAssertTrue(reused === resolver)
        XCTAssertEqual(reused.candidateHosts, ["192.168.1.50", "100.64.0.1", "studio.local"])
    }

    /// A stream outlives many overviews and only the delivery that actually widens the candidates gets a
    /// merged record back, so the record it publishes has to move forward and stay forward.
    func testASubscriptionKeepsPublishingTheWidenedRecordOnEveryLaterDelivery() throws {
        let database = try makeDatabase()
        try database.upsert(device: Self.device)

        var published: [[String]] = []
        var record = Self.device
        // Stands in for the subscription's delivery loop, which merges against the record it is currently
        // publishing with rather than the one captured when the stream opened.
        for _ in 0..<3 {
            if let merged = SpacesDeviceClient.mergeAdvertisedHosts(
                device: record, status: Self.daemonStatus(advertised: ["192.168.1.50"]), database: database)
            {
                record = merged
            }
            published.append(record.hosts)
        }

        // The first delivery learns the address; the two after it report nothing new, and must not fall
        // back to the record the stream opened with.
        XCTAssertEqual(published, Array(repeating: ["192.168.1.50", "studio.local"], count: 3))
    }

    func testOverviewWithNoAdvertisedAddressesChangesNothing() throws {
        let database = try makeDatabase()
        try database.upsert(device: Self.device)
        let resolver = SpacesDeviceEndpointRegistry.resolver(for: Self.device, certificateFingerprint: Self.device.certificateFingerprint)

        _ = try SpacesDeviceClient.resolveOverview(
            device: Self.device, clientApp: Self.clientApp, profile: nil, requestProvider: Self.requestProvider(advertised: []), database: database)

        // An empty list means the daemon reported nothing, never that it has no addresses.
        XCTAssertEqual(try database.pairedDevice(id: Self.device.id)?.hosts, ["studio.local"])
        XCTAssertEqual(resolver.candidateHosts, ["studio.local"])
    }

    func testLocalDeviceKeepsItsLoopbackCandidateRegardlessOfWhatItAdvertises() throws {
        let database = try makeDatabase()
        try database.upsert(device: Self.localDevice)
        let resolver = SpacesDeviceEndpointRegistry.resolver(for: Self.localDevice, certificateFingerprint: Self.localDevice.certificateFingerprint)

        _ = try SpacesDeviceClient.resolveOverview(
            device: Self.localDevice, clientApp: Self.clientApp, profile: nil,
            requestProvider: Self.requestProvider(advertised: ["192.168.1.50", "100.64.0.1"]), database: database)

        // This Mac's own daemon is reached over loopback and re-resolves itself through the control
        // socket, so its outward-facing addresses are never the right way to reach it from here.
        XCTAssertEqual(try database.pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID)?.hosts, ["127.0.0.1"])
        XCTAssertEqual(resolver.candidateHosts, ["127.0.0.1"])
    }

    // MARK: - Fixtures

    private static let clientApp = SpacesDeviceClientApp(installationID: "i", bundleID: "b", platform: "macos", deviceName: "Mac", appVersion: "1.0")

    private static let device = SpacesPairedDeviceRecord(
        id: "device-advertised", name: "Studio Mac", platform: "macos", hosts: ["studio.local"], port: 7443,
        certificateFingerprint: "SHA256:advertised", createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z")

    private static let localDevice = SpacesPairedDeviceRecord(
        id: SpacesPairedDeviceRecord.localDeviceID, name: "This Mac", platform: "macos", hosts: ["127.0.0.1"], port: 47_848,
        certificateFingerprint: "SHA256:local-advertised", createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z")

    private static func daemonStatus(advertised: [String]) -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, deviceAPIAddresses: advertised)
    }

    private static func requestProvider(advertised: [String]) -> SpacesDeviceClient.DeviceRequestProvider {
        { _, _, _, _ in
            SpacesDeviceAPIResponse(
                ok: true, message: "ok",
                result: .overview(
                    SpacesDeviceOverviewPayload(
                        workspaces: [], sessions: [],
                        daemonStatus: TerminalServiceDaemonStatus(
                            version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                            deviceAPIAddresses: advertised))))
        }
    }

    private func makeDatabase() throws -> SpacesClientDatabase {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
    }
}
