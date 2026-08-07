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
