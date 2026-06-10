import Foundation
import XCTest
import spacesmobilecore

@testable import spacesmobilebridge

final class SpacesMobilePairingCoordinatorTests: XCTestCase {
    func testOpenWindowGeneratesFreshEightDigitCodes() {
        let coordinator = SpacesMobilePairingCoordinator()
        let first = coordinator.openWindow(
            host: "127.0.0.1", port: 47_847, transportKey: SpacesMobileBridgeSettings.generateTransportKey(), name: "Mac")
        let second = coordinator.openWindow(
            host: "127.0.0.1", port: 47_847, transportKey: SpacesMobileBridgeSettings.generateTransportKey(), name: "Mac")

        XCTAssertEqual(first.code.count, 8)
        XCTAssertEqual(second.code.count, 8)
        XCTAssertNotEqual(first.nonce, second.nonce)
    }

    func testRejectsNoWindowExpiredWindowAndSingleUseReplay() {
        let coordinator = SpacesMobilePairingCoordinator()
        XCTAssertThrowsError(try coordinator.validate(code: "12345678", nonce: "nonce", peerID: "peer"))

        let now = Date()
        let window = coordinator.openWindow(
            host: "127.0.0.1", port: 47_847, transportKey: SpacesMobileBridgeSettings.generateTransportKey(), name: "Mac", now: now, duration: 10,
            code: "12345678", nonce: "nonce")

        XCTAssertThrowsError(try coordinator.validate(code: window.code, nonce: window.nonce, peerID: "peer", now: now.addingTimeInterval(11)))

        let fresh = coordinator.openWindow(
            host: "127.0.0.1", port: 47_847, transportKey: SpacesMobileBridgeSettings.generateTransportKey(), name: "Mac", now: now, duration: 10,
            code: "87654321", nonce: "fresh")
        XCTAssertNoThrow(try coordinator.validate(code: fresh.code, nonce: fresh.nonce, peerID: "peer", now: now))
        XCTAssertThrowsError(try coordinator.validate(code: fresh.code, nonce: fresh.nonce, peerID: "peer", now: now))
    }

    func testFailedAttemptLockoutUsesGenericError() {
        let coordinator = SpacesMobilePairingCoordinator()
        let window = coordinator.openWindow(
            host: "127.0.0.1", port: 47_847, transportKey: SpacesMobileBridgeSettings.generateTransportKey(), name: "Mac", code: "12345678",
            nonce: "nonce")

        for _ in 0..<SpacesMobilePairingCoordinator.maxFailedAttempts {
            XCTAssertThrowsError(try coordinator.validate(code: "00000000", nonce: window.nonce, peerID: "peer")) { error in
                XCTAssertEqual(error.localizedDescription, SpacesMobilePairingCoordinatorError.failed.localizedDescription)
            }
        }
        XCTAssertThrowsError(try coordinator.validate(code: window.code, nonce: window.nonce, peerID: "peer"))
    }

    func testPairingLinkBuildAndParseRoundTrips() throws {
        let key = SpacesMobileBridgeSettings.generateTransportKey()
        let link = SpacesMobilePairingLink(
            host: "mac.local", port: 47_847, nonce: "NONCE", code: "12345678", transportKey: key, certificateFingerprint: "SHA256:test",
            name: "Spaces Mac")

        XCTAssertEqual(try SpacesMobilePairingLink.parse(link.absoluteString), link)
    }

    func testPairingLinkParseRejectsDuplicateQueryKeys() {
        let link =
            "spacesmobile://pair?v=1&host=mac.local&host=other.local&port=47847&nonce=NONCE&code=12345678&psk=transport&fp=SHA256:test&name=Mac"

        XCTAssertThrowsError(try SpacesMobilePairingLink.parse(link)) { error in XCTAssertEqual(error as? SpacesMobilePairingLinkError, .invalidLink)
        }
    }
}
