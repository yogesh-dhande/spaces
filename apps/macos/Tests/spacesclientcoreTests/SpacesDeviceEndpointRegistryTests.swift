import XCTest
import spacesdevicecore

@testable import spacesclientcore

/// Covers the registry's ownership of one resolver per endpoint, what that resolver's candidate list is
/// reconciled against, and the wholesale invalidation the Mac app's network-path watcher performs when
/// this client's own network changes underneath it.
final class SpacesDeviceEndpointRegistryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SpacesDeviceEndpointRegistry.resetForTesting()
    }

    override func tearDown() {
        SpacesDeviceEndpointRegistry.resetForTesting()
        super.tearDown()
    }

    func testResolverIsSharedPerEndpointAndSeparatePerFingerprint() throws {
        let database = try makeDatabase(devices: [Self.studio, Self.linuxBox])

        let first = sharedResolver(for: Self.studio, database: database)
        let second = sharedResolver(for: Self.studio, database: database)
        let other = sharedResolver(for: Self.linuxBox, database: database)

        XCTAssertTrue(first === second)
        XCTAssertFalse(first === other)
    }

    /// The stored row is the authority on where a device is dialed. A re-pair rewrites it, and so does
    /// another process writing the shared client database, and the live resolver has to pick that up
    /// rather than keep dialing the list it was constructed with until the app relaunches.
    func testResolverAdoptsTheStoredCandidatesRatherThanTheOnesItWasBuiltWith() throws {
        let database = try makeDatabase(devices: [Self.studio])
        let first = sharedResolver(for: Self.studio, database: database)
        XCTAssertEqual(first.candidateHosts, ["192.168.1.50", "100.64.0.4"])

        var moved = Self.studio
        moved.hosts = ["10.10.0.3", "100.64.0.4"]
        try database.upsert(device: moved)
        let second = sharedResolver(for: Self.studio, database: database)

        // Still the one shared resolver, so the command path and the stream paths stay converged on one
        // cached winner, and it now dials what the database says.
        XCTAssertTrue(first === second)
        XCTAssertEqual(second.candidateHosts, ["10.10.0.3", "100.64.0.4"])
        // The proven address was dropped because the new list no longer contains it, which is the same
        // membership rule construction applies.
        XCTAssertNil(second.currentCachedHost())
    }

    /// The regression this authority exists for. A terminal pane's model captures its record when the
    /// pane opens and passes that same value to every stream reconnect for the life of the pane, so a
    /// record read minutes ago is replayed indefinitely. If the caller's copy were trusted, each of those
    /// reconnects would narrow the shared resolver back to the pane's original list and strip out every
    /// address learned since.
    func testALongLivedHoldersStaleRecordCannotStripAnAddressLearnedSinceItWasRead() throws {
        let database = try makeDatabase(devices: [Self.studio])
        // What the pane captured when it opened, and keeps passing on every reconnect.
        let captured = Self.studio
        let resolver = sharedResolver(for: captured, database: database)

        // The daemon later advertises a tailnet address this client had never seen, which the merge folds
        // into the stored row and the live resolver.
        let merged = try XCTUnwrap(database.mergeAdvertisedHosts(deviceID: Self.studio.id, advertised: ["192.168.1.50", "100.64.0.9"]))
        SpacesDeviceEndpointRegistry.refresh(record: merged)
        XCTAssertEqual(resolver.candidateHosts, ["192.168.1.50", "100.64.0.9", "100.64.0.4"])

        // The pane reconnects with the record it captured before any of that happened.
        let reconnected = SpacesDeviceEndpointRegistry.resolver(
            for: captured, certificateFingerprint: captured.certificateFingerprint, database: database)

        XCTAssertTrue(reconnected === resolver)
        XCTAssertEqual(reconnected.candidateHosts, ["192.168.1.50", "100.64.0.9", "100.64.0.4"])
    }

    /// A device whose row is gone was deleted or re-paired under a new identity. Emptying the resolver's
    /// candidates would turn the next attempt into "no address at all" rather than the honest failure the
    /// connection is already about to produce.
    func testADeletedRowLeavesTheResolversCandidatesAlone() throws {
        let database = try makeDatabase(devices: [Self.studio])
        let resolver = sharedResolver(for: Self.studio, database: database)

        try database.deletePairedDevice(id: Self.studio.id)
        let afterDelete = sharedResolver(for: Self.studio, database: database)

        XCTAssertTrue(afterDelete === resolver)
        XCTAssertEqual(afterDelete.candidateHosts, ["192.168.1.50", "100.64.0.4"])
    }

    /// The resolver's own cached winner is never staler than the stored `active_host`, since that column
    /// is written by the resolver. Re-seeding it on every lookup would undo the invalidation the
    /// network-path watcher just performed.
    func testReconcilingDoesNotResurrectAProvenAddressThatWasDeliberatelyCleared() throws {
        let database = try makeDatabase(devices: [Self.studio])
        let resolver = sharedResolver(for: Self.studio, database: database)
        SpacesDeviceEndpointRegistry.resetAllForNetworkChange()

        // The stored row still names the address that was proven before the network moved.
        XCTAssertEqual(try database.pairedDevice(id: Self.studio.id)?.activeHost, "192.168.1.50")
        var widened = Self.studio
        widened.hosts = ["192.168.1.50", "100.64.0.4", "studio.local"]
        try database.upsert(device: widened)
        _ = sharedResolver(for: Self.studio, database: database)

        XCTAssertNil(resolver.currentCachedHost())
        XCTAssertEqual(resolver.candidateHosts, ["192.168.1.50", "100.64.0.4", "studio.local"])
    }

    func testNetworkChangeResetDropsEveryDevicesProvenAddress() throws {
        let database = try makeDatabase(devices: [Self.studio, Self.linuxBox])
        let studio = sharedResolver(for: Self.studio, database: database)
        let linuxBox = sharedResolver(for: Self.linuxBox, database: database)
        // Both start warm: each record carries the address its last connection was proven on.
        XCTAssertEqual(studio.currentCachedHost(), "192.168.1.50")
        XCTAssertEqual(linuxBox.currentCachedHost(), "100.64.0.9")

        SpacesDeviceEndpointRegistry.resetAllForNetworkChange()

        // Neither device goes straight back to an address proven on a network this client may have left;
        // the candidate lists themselves are untouched, so the next connect re-races them from the top.
        XCTAssertNil(studio.currentCachedHost())
        XCTAssertNil(linuxBox.currentCachedHost())
        XCTAssertEqual(studio.candidateHosts, ["192.168.1.50", "100.64.0.4"])
        XCTAssertEqual(linuxBox.candidateHosts, ["10.0.0.7", "100.64.0.9"])
    }

    /// The stream's own rotation state is learned about a network too, so the reset has to take it with
    /// the cached winner: a LAN address marked failed while away from that network would otherwise stay
    /// skipped after the client comes home.
    func testNetworkChangeResetAlsoClearsWhatAStreamFoundDead() throws {
        let database = try makeDatabase(devices: [Self.studio])
        let resolver = sharedResolver(for: Self.studio, database: database)

        // Away from home: the LAN address fails and the stream converges on the tailnet one.
        resolver.noteStreamFailed(host: "192.168.1.50")
        XCTAssertEqual(resolver.nextStreamHost(), "100.64.0.4")

        SpacesDeviceEndpointRegistry.resetAllForNetworkChange()

        // Back home, the stream starts from the preferred candidate again instead of skipping it.
        XCTAssertEqual(resolver.nextStreamHost(), "192.168.1.50")
    }

    private func sharedResolver(for device: SpacesPairedDeviceRecord, database: SpacesClientDatabase) -> SpacesDeviceEndpointResolver {
        SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: device.certificateFingerprint, database: database)
    }

    private func makeDatabase(devices: [SpacesPairedDeviceRecord]) throws -> SpacesClientDatabase {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = try SpacesClientDatabase(path: root.appendingPathComponent("spaces-client.db").path)
        for device in devices { try database.upsert(device: device) }
        return database
    }

    private static let studio = SpacesPairedDeviceRecord(
        id: "device-studio", name: "Studio Mac", platform: "macos", hosts: ["192.168.1.50", "100.64.0.4"], activeHost: "192.168.1.50", port: 7443,
        certificateFingerprint: "SHA256:studio", createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z")

    private static let linuxBox = SpacesPairedDeviceRecord(
        id: "device-linux", name: "Linux Box", platform: "linux", hosts: ["10.0.0.7", "100.64.0.9"], activeHost: "100.64.0.9", port: 7443,
        certificateFingerprint: "SHA256:linux", createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z")
}
