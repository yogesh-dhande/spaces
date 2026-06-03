import Network
import XCTest
import spacesmobilecore

final class SpacesMobileBridgeAuthenticationTests: XCTestCase {
    func testRecoveryMessageMatchesUnpairedInstallationError() {
        let error = NSError(
            domain: "SpacesMobileBridgeServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "The mobile installation 'ABC-123' is not paired."])

        XCTAssertEqual(
            SpacesMobileBridgeAuthentication.recoveryMessage(for: error),
            "This Mac no longer recognizes this device. Open Connection and pair this device again.")
    }

    func testRecoveryMessageMatchesInvalidAuthTokenError() {
        let error = NSError(domain: "SpacesMobileBridgeServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid mobile auth token."])

        XCTAssertEqual(
            SpacesMobileBridgeAuthentication.recoveryMessage(for: error),
            "This Mac no longer recognizes this device. Open Connection and pair this device again.")
    }

    func testRecoveryMessageMatchesTransportAuthenticationFailure() {
        let error = NWError.tls(-9800)

        XCTAssertEqual(
            SpacesMobileBridgeAuthentication.recoveryMessage(for: error),
            "This Mac no longer recognizes this device. Open Connection and pair this device again.")
    }

    func testRecoveryMessageMatchesTransportAuthenticationTimeoutProbeFailure() {
        let error = NSError(
            domain: "SpacesMobileBridgeClient", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The secure mobile bridge transport could not authenticate."])

        XCTAssertEqual(
            SpacesMobileBridgeAuthentication.recoveryMessage(for: error),
            "This Mac no longer recognizes this device. Open Connection and pair this device again.")
    }

    func testRecoveryMessageIgnoresAvailabilityError() {
        let error = NSError(
            domain: "SpacesMobileBridgeServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Terminal session 'ABC-123' is not available."])

        XCTAssertNil(SpacesMobileBridgeAuthentication.recoveryMessage(for: error))
    }

    func testRecoveryMessageIgnoresConnectionRefused() {
        XCTAssertNil(SpacesMobileBridgeAuthentication.recoveryMessage(for: NWError.posix(.ECONNREFUSED)))
    }
}
