import XCTest
import spacesdevicecore

@testable import spacesclientcore

/// Covers the registry's ownership of one resolver per endpoint, and the wholesale invalidation the
/// Mac app's network-path watcher performs when this client's own network changes underneath it.
final class SpacesDeviceEndpointRegistryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SpacesDeviceEndpointRegistry.resetForTesting()
    }

    override func tearDown() {
        SpacesDeviceEndpointRegistry.resetForTesting()
        super.tearDown()
    }

    func testResolverIsSharedPerEndpointAndSeparatePerFingerprint() {
        let first = SpacesDeviceEndpointRegistry.resolver(for: Self.studio, certificateFingerprint: Self.studio.certificateFingerprint)
        let second = SpacesDeviceEndpointRegistry.resolver(for: Self.studio, certificateFingerprint: Self.studio.certificateFingerprint)
        let other = SpacesDeviceEndpointRegistry.resolver(for: Self.linuxBox, certificateFingerprint: Self.linuxBox.certificateFingerprint)

        XCTAssertTrue(first === second)
        XCTAssertFalse(first === other)
    }

    /// A record read after the resolver was built can carry different candidates: a re-pair rewrites
    /// them, and so does another process writing the shared client database. The live resolver has to
    /// pick those up rather than keep dialing the list it was constructed with until the app relaunches.
    func testResolverAdoptsTheCandidatesOfTheRecordItIsAskedFor() {
        var device = Self.studio
        let first = SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: device.certificateFingerprint)
        XCTAssertEqual(first.candidateHosts, ["192.168.1.50", "100.64.0.4"])

        device.hosts = ["10.10.0.3", "100.64.0.4"]
        let second = SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: device.certificateFingerprint)

        // Still the one shared resolver, so the command path and the stream paths stay converged on one
        // cached winner, and it now dials what the record says.
        XCTAssertTrue(first === second)
        XCTAssertEqual(second.candidateHosts, ["10.10.0.3", "100.64.0.4"])
        // The proven address was dropped because the new list no longer contains it, which is the same
        // membership rule construction applies.
        XCTAssertNil(second.currentCachedHost())
    }

    /// The resolver's own cached winner is never staler than the record's persisted `active_host`, since
    /// that column is written by the resolver. Re-seeding it from the record on every lookup would undo
    /// the invalidation the network-path watcher just performed.
    func testReconcilingDoesNotResurrectAProvenAddressThatWasDeliberatelyCleared() {
        var device = Self.studio
        let resolver = SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: device.certificateFingerprint)
        SpacesDeviceEndpointRegistry.clearAllCachedWinners()

        // The record still names the address that was proven before the network moved.
        XCTAssertEqual(device.activeHost, "192.168.1.50")
        device.hosts = ["192.168.1.50", "100.64.0.4", "studio.local"]
        _ = SpacesDeviceEndpointRegistry.resolver(for: device, certificateFingerprint: device.certificateFingerprint)

        XCTAssertNil(resolver.currentCachedHost())
        XCTAssertEqual(resolver.candidateHosts, ["192.168.1.50", "100.64.0.4", "studio.local"])
    }

    func testClearingAllCachedWinnersDropsEveryDevicesProvenAddress() {
        let studio = SpacesDeviceEndpointRegistry.resolver(for: Self.studio, certificateFingerprint: Self.studio.certificateFingerprint)
        let linuxBox = SpacesDeviceEndpointRegistry.resolver(for: Self.linuxBox, certificateFingerprint: Self.linuxBox.certificateFingerprint)
        // Both start warm: each record carries the address its last connection was proven on.
        XCTAssertEqual(studio.currentCachedHost(), "192.168.1.50")
        XCTAssertEqual(linuxBox.currentCachedHost(), "100.64.0.9")

        SpacesDeviceEndpointRegistry.clearAllCachedWinners()

        // Neither device goes straight back to an address proven on a network this client may have left;
        // the candidate lists themselves are untouched, so the next connect re-races them from the top.
        XCTAssertNil(studio.currentCachedHost())
        XCTAssertNil(linuxBox.currentCachedHost())
        XCTAssertEqual(studio.candidateHosts, ["192.168.1.50", "100.64.0.4"])
        XCTAssertEqual(linuxBox.candidateHosts, ["10.0.0.7", "100.64.0.9"])
    }

    private static let studio = SpacesPairedDeviceRecord(
        id: "device-studio", name: "Studio Mac", platform: "macos", hosts: ["192.168.1.50", "100.64.0.4"], activeHost: "192.168.1.50", port: 7443,
        certificateFingerprint: "SHA256:studio", createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z")

    private static let linuxBox = SpacesPairedDeviceRecord(
        id: "device-linux", name: "Linux Box", platform: "linux", hosts: ["10.0.0.7", "100.64.0.9"], activeHost: "100.64.0.9", port: 7443,
        certificateFingerprint: "SHA256:linux", createdAt: "2026-06-17T00:00:00Z", updatedAt: "2026-06-17T00:00:00Z")
}
