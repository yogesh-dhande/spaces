import Foundation
import XCTest
import spacesdevicecore

@testable import spacesdeviceapi

final class SpacesDevicePairingCoordinatorTests: XCTestCase {
    func testOpenWindowGeneratesFreshEightDigitCodes() {
        let coordinator = SpacesDevicePairingCoordinator()
        let first = coordinator.openWindow(host: "127.0.0.1", port: 47_847, certificateFingerprint: "SHA256:test", name: "Mac")
        let second = coordinator.openWindow(
            host: "127.0.0.1", port: 47_847, certificateFingerprint: "SHA256:test", name: "Mac")

        XCTAssertEqual(first.code.count, 8)
        XCTAssertEqual(second.code.count, 8)
        XCTAssertNotEqual(first.nonce, second.nonce)
    }

    func testRejectsNoWindowExpiredWindowAndSingleUseReplay() {
        let coordinator = SpacesDevicePairingCoordinator()
        XCTAssertThrowsError(try coordinator.validate(code: "12345678", nonce: "nonce", peerID: "peer"))

        let now = Date()
        let window = coordinator.openWindow(
            host: "127.0.0.1", port: 47_847, certificateFingerprint: "SHA256:test", name: "Mac", now: now, duration: 10,
            code: "12345678", nonce: "nonce")

        XCTAssertThrowsError(try coordinator.validate(code: window.code, nonce: window.nonce, peerID: "peer", now: now.addingTimeInterval(11)))

        let fresh = coordinator.openWindow(
            host: "127.0.0.1", port: 47_847, certificateFingerprint: "SHA256:test", name: "Mac", now: now, duration: 10,
            code: "87654321", nonce: "fresh")
        XCTAssertNoThrow(try coordinator.validate(code: fresh.code, nonce: fresh.nonce, peerID: "peer", now: now))
        XCTAssertThrowsError(try coordinator.validate(code: fresh.code, nonce: fresh.nonce, peerID: "peer", now: now))
    }

    func testFailedAttemptLockoutUsesGenericError() {
        let coordinator = SpacesDevicePairingCoordinator()
        let window = coordinator.openWindow(
            host: "127.0.0.1", port: 47_847, certificateFingerprint: "SHA256:test", name: "Mac", code: "12345678",
            nonce: "nonce")

        for _ in 0..<SpacesDevicePairingCoordinator.maxFailedAttempts {
            XCTAssertThrowsError(try coordinator.validate(code: "00000000", nonce: window.nonce, peerID: "peer")) { error in
                XCTAssertEqual(error.localizedDescription, SpacesDevicePairingCoordinatorError.failed.localizedDescription)
            }
        }
        XCTAssertThrowsError(try coordinator.validate(code: window.code, nonce: window.nonce, peerID: "peer"))
    }

    func testPairingLinkBuildAndParseRoundTrips() throws {
        let link = SpacesDevicePairingLink(
            host: "mac.local", port: 47_847, nonce: "NONCE", code: "12345678", certificateFingerprint: "SHA256:test", name: "Spaces Mac")

        XCTAssertEqual(try SpacesDevicePairingLink.parse(link.absoluteString), link)
        XCTAssertTrue(link.absoluteString.hasPrefix("spaces://pair?"))
    }

    func testPairingLinkParseRejectsDuplicateQueryKeys() {
        let link = "spaces://pair?v=2&host=mac.local&host=other.local&port=47847&nonce=NONCE&code=12345678&fp=SHA256:test&name=Mac"

        XCTAssertThrowsError(try SpacesDevicePairingLink.parse(link)) { error in XCTAssertEqual(error as? SpacesDevicePairingLinkError, .invalidLink)
        }
    }

    func testPairingLinkRejectsUnsupportedScheme() {
        let link = "spaceswrong://pair?v=2&host=mac.local&port=47847&nonce=NONCE&code=12345678&fp=SHA256:test&name=Mac"

        XCTAssertThrowsError(try SpacesDevicePairingLink.parse(link)) { error in XCTAssertEqual(error as? SpacesDevicePairingLinkError, .invalidLink)
        }
    }

    func testPairingLinkRejectsLegacyTransportKeyVersion() {
        let link = "spaces://pair?v=1&host=mac.local&port=47847&nonce=NONCE&code=12345678&psk=transport&fp=SHA256:test&name=Mac"

        XCTAssertThrowsError(try SpacesDevicePairingLink.parse(link)) { error in
            XCTAssertEqual(error as? SpacesDevicePairingLinkError, .unsupportedVersion)
        }
    }

    func testPairingLinkRequiresCertificateFingerprint() {
        let link = "spaces://pair?v=2&host=mac.local&port=47847&nonce=NONCE&code=12345678&name=Mac"

        XCTAssertThrowsError(try SpacesDevicePairingLink.parse(link)) { error in
            XCTAssertEqual(error as? SpacesDevicePairingLinkError, .missingField("fp"))
        }
    }
}
