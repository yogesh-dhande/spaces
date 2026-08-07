import Foundation
import XCTest
import spacesclientcore
import spacesdevicecore

@testable import spacesdeviceapi

final class SpacesDevicePairingCoordinatorTests: XCTestCase {
    func testOpenWindowGeneratesFreshEightDigitCodes() {
        let coordinator = SpacesDevicePairingCoordinator()
        let first = coordinator.openWindow(
            hosts: ["127.0.0.1"], port: 47_847, certificateFingerprint: "SHA256:test", name: "Mac", protocolVersion: 5, appVersion: "0.1.0")
        let second = coordinator.openWindow(
            hosts: ["127.0.0.1"], port: 47_847, certificateFingerprint: "SHA256:test", name: "Mac", protocolVersion: 5, appVersion: "0.1.0")

        XCTAssertEqual(first.code.count, 8)
        XCTAssertEqual(second.code.count, 8)
        XCTAssertNotEqual(first.nonce, second.nonce)
        // The daemon's protocol/app version ride along in the link for the pairing-time gate.
        XCTAssertEqual(first.link.protocolVersion, 5)
        XCTAssertEqual(first.link.appVersion, "0.1.0")
    }

    func testRejectsNoWindowExpiredWindowAndSingleUseReplay() {
        let coordinator = SpacesDevicePairingCoordinator()
        XCTAssertThrowsError(try coordinator.validate(code: "12345678", nonce: "nonce", peerID: "peer"))

        let now = Date()
        let window = coordinator.openWindow(
            hosts: ["127.0.0.1"], port: 47_847, certificateFingerprint: "SHA256:test", name: "Mac", protocolVersion: 5, appVersion: "0.1.0", now: now,
            duration: 10, code: "12345678", nonce: "nonce")

        XCTAssertThrowsError(try coordinator.validate(code: window.code, nonce: window.nonce, peerID: "peer", now: now.addingTimeInterval(11)))

        let fresh = coordinator.openWindow(
            hosts: ["127.0.0.1"], port: 47_847, certificateFingerprint: "SHA256:test", name: "Mac", protocolVersion: 5, appVersion: "0.1.0", now: now,
            duration: 10, code: "87654321", nonce: "fresh")
        XCTAssertNoThrow(try coordinator.validate(code: fresh.code, nonce: fresh.nonce, peerID: "peer", now: now))
        XCTAssertThrowsError(try coordinator.validate(code: fresh.code, nonce: fresh.nonce, peerID: "peer", now: now))
    }

    func testFailedAttemptLockoutUsesGenericError() {
        let coordinator = SpacesDevicePairingCoordinator()
        let window = coordinator.openWindow(
            hosts: ["127.0.0.1"], port: 47_847, certificateFingerprint: "SHA256:test", name: "Mac", protocolVersion: 5, appVersion: "0.1.0",
            code: "12345678", nonce: "nonce")

        for _ in 0..<SpacesDevicePairingCoordinator.maxFailedAttempts {
            XCTAssertThrowsError(try coordinator.validate(code: "00000000", nonce: window.nonce, peerID: "peer")) { error in
                XCTAssertEqual(error.localizedDescription, SpacesDevicePairingCoordinatorError.failed.localizedDescription)
            }
        }
        XCTAssertThrowsError(try coordinator.validate(code: window.code, nonce: window.nonce, peerID: "peer"))
    }

    func testPairingLinkBuildAndParseRoundTrips() throws {
        let link = SpacesDevicePairingLink(
            hosts: ["mac.local"], port: 47_847, nonce: "NONCE", code: "12345678", certificateFingerprint: "SHA256:test", name: "Spaces Mac",
            protocolVersion: 5, appVersion: "0.1.0")

        let parsed = try SpacesDevicePairingLink.parse(link.absoluteString)
        XCTAssertEqual(parsed, link)
        XCTAssertEqual(parsed.protocolVersion, 5)
        XCTAssertEqual(parsed.appVersion, "0.1.0")
        XCTAssertTrue(link.absoluteString.hasPrefix("spaces://pair?"))
    }

    func testPairingLinkBuildAndParseRoundTripsMultipleHostsInOrder() throws {
        let link = SpacesDevicePairingLink(
            hosts: ["192.168.1.24", "100.86.197.104"], port: 47_847, nonce: "NONCE", code: "12345678", certificateFingerprint: "SHA256:test",
            name: "Spaces Mac", protocolVersion: 5, appVersion: "0.1.0")

        let parsed = try SpacesDevicePairingLink.parse(link.absoluteString)
        XCTAssertEqual(parsed, link)
        XCTAssertEqual(parsed.hosts, ["192.168.1.24", "100.86.197.104"])
        XCTAssertEqual(parsed.port, 47_847)
        XCTAssertEqual(parsed.nonce, "NONCE")
        XCTAssertEqual(parsed.code, "12345678")
        XCTAssertEqual(parsed.certificateFingerprint, "SHA256:test")
        XCTAssertEqual(parsed.name, "Spaces Mac")
        XCTAssertEqual(parsed.protocolVersion, 5)
        XCTAssertEqual(parsed.appVersion, "0.1.0")
    }

    func testPairingLinkParseCollectsRepeatedHostsInOrder() throws {
        let link = "spaces://pair?v=4&host=mac.local&host=other.local&port=47847&nonce=NONCE&code=12345678&fp=SHA256:test&name=Mac&pv=5&av=0.1.0"

        let parsed = try SpacesDevicePairingLink.parse(link)
        XCTAssertEqual(parsed.hosts, ["mac.local", "other.local"])
    }

    /// A link is untrusted input and `host` is the one parameter that may repeat, so a scanned or pasted
    /// link cannot hand a client an unbounded candidate list to race and then persist. Every address a
    /// list carries is something a connect may have to walk — a race stages its attempts, and a stream
    /// rotates one reconnect at a time — so an unbounded list is an unbounded connect.
    func testPairingLinkParseNormalizesAndCapsAnAbusiveHostList() throws {
        let parsed = try SpacesDevicePairingLink.parse(Self.abusiveHostListLink)

        XCTAssertEqual(parsed.hosts, Self.abusiveHostListExpectation)
        XCTAssertEqual(parsed.hosts.count, SpacesDeviceHostCandidates.maxCount)
    }

    /// The cap is the same number the stored record and the advertised-host merge are bounded by, so a
    /// redeemed link can never carry more candidates than a record is allowed to keep.
    func testTheLinkCapIsTheSameBoundTheStoredRecordUses() {
        XCTAssertEqual(SpacesDeviceHostCandidates.maxCount, SpacesPairedDeviceRecord.maxHostCandidates)
    }

    /// A link whose `host` parameter is repeated far past what any device has, with a whitespace-padded
    /// entry, a duplicate of it, and an empty one mixed in. Percent-encoded, because this has to be a
    /// link a client could really be handed.
    static let abusiveHostListLink: String = {
        let hosts = ["%20%20192.168.1.24%20%20", "192.168.1.24", "", "100.86.197.104"] + (1...20).map { "10.0.0.\($0)" }
        return "spaces://pair?v=4&" + hosts.map { "host=\($0)" }.joined(separator: "&")
            + "&port=47847&nonce=NONCE&code=12345678&fp=SHA256:test&name=Mac&pv=5&av=0.1.0"
    }()

    /// What `abusiveHostListLink` must reduce to: trimmed, empties dropped, duplicates removed keeping
    /// the first occurrence, capped from the tail so the most-preferred addresses survive.
    static let abusiveHostListExpectation = ["192.168.1.24", "100.86.197.104", "10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4"]

    func testPairingLinkParseAcceptsSingleHost() throws {
        let link = "spaces://pair?v=4&host=mac.local&port=47847&nonce=NONCE&code=12345678&fp=SHA256:test&name=Mac&pv=5&av=0.1.0"

        let parsed = try SpacesDevicePairingLink.parse(link)
        XCTAssertEqual(parsed.hosts, ["mac.local"])
    }

    func testPairingLinkParseRejectsDuplicateNonHostQueryKeys() {
        let link = "spaces://pair?v=4&host=mac.local&port=47847&port=47848&nonce=NONCE&code=12345678&fp=SHA256:test&name=Mac&pv=5&av=0.1.0"

        XCTAssertThrowsError(try SpacesDevicePairingLink.parse(link)) { error in XCTAssertEqual(error as? SpacesDevicePairingLinkError, .invalidLink)
        }
    }

    func testPairingLinkRejectsUnsupportedScheme() {
        let link = "spaceswrong://pair?v=4&host=mac.local&port=47847&nonce=NONCE&code=12345678&fp=SHA256:test&name=Mac&pv=5&av=0.1.0"

        XCTAssertThrowsError(try SpacesDevicePairingLink.parse(link)) { error in XCTAssertEqual(error as? SpacesDevicePairingLinkError, .invalidLink)
        }
    }

    func testPairingLinkRejectsLegacyVersions() {
        for legacy in ["1", "2", "3"] {
            let link = "spaces://pair?v=\(legacy)&host=mac.local&port=47847&nonce=NONCE&code=12345678&psk=transport&fp=SHA256:test&name=Mac"
            XCTAssertThrowsError(try SpacesDevicePairingLink.parse(link)) { error in
                XCTAssertEqual(error as? SpacesDevicePairingLinkError, .unsupportedVersion)
            }
        }
    }

    func testPairingLinkRequiresAtLeastOneHost() {
        let link = "spaces://pair?v=4&port=47847&nonce=NONCE&code=12345678&fp=SHA256:test&name=Mac&pv=5&av=0.1.0"

        XCTAssertThrowsError(try SpacesDevicePairingLink.parse(link)) { error in
            XCTAssertEqual(error as? SpacesDevicePairingLinkError, .missingField("host"))
        }
    }

    func testPairingLinkRequiresCertificateFingerprint() {
        let link = "spaces://pair?v=4&host=mac.local&port=47847&nonce=NONCE&code=12345678&name=Mac&pv=5&av=0.1.0"

        XCTAssertThrowsError(try SpacesDevicePairingLink.parse(link)) { error in
            XCTAssertEqual(error as? SpacesDevicePairingLinkError, .missingField("fp"))
        }
    }

    func testPairingLinkRequiresProtocolAndAppVersion() {
        let missingProtocol = "spaces://pair?v=4&host=mac.local&port=47847&nonce=NONCE&code=12345678&fp=SHA256:test&name=Mac&av=0.1.0"
        XCTAssertThrowsError(try SpacesDevicePairingLink.parse(missingProtocol)) { error in
            XCTAssertEqual(error as? SpacesDevicePairingLinkError, .missingField("pv"))
        }

        let missingAppVersion = "spaces://pair?v=4&host=mac.local&port=47847&nonce=NONCE&code=12345678&fp=SHA256:test&name=Mac&pv=5"
        XCTAssertThrowsError(try SpacesDevicePairingLink.parse(missingAppVersion)) { error in
            XCTAssertEqual(error as? SpacesDevicePairingLinkError, .missingField("av"))
        }
    }
}
