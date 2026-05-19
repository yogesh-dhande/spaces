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

    func testRecoveryMessageIgnoresAvailabilityError() {
        let error = NSError(
            domain: "SpacesMobileBridgeServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Terminal session 'ABC-123' is not available."])

        XCTAssertNil(SpacesMobileBridgeAuthentication.recoveryMessage(for: error))
    }
}
