import Network
import XCTest
import spacesdevicecore

final class SpacesDeviceAPIAuthenticationTests: XCTestCase {
    func testRecoveryMessageMatchesUnpairedInstallationError() {
        let error = NSError(
            domain: "SpacesDeviceAPIServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "The client installation 'ABC-123' is not paired."])

        XCTAssertEqual(
            SpacesDeviceAPIAuthentication.recoveryMessage(for: error),
            "This Mac no longer recognizes this device. Open Devices and pair this device again.")
    }

    func testRecoveryMessageMatchesInvalidAuthTokenError() {
        let error = NSError(domain: "SpacesDeviceAPIServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])

        XCTAssertEqual(
            SpacesDeviceAPIAuthentication.recoveryMessage(for: error),
            "This Mac no longer recognizes this device. Open Devices and pair this device again.")
    }

    func testRecoveryMessageMatchesTransportAuthenticationFailure() {
        let error = NWError.tls(-9800)

        XCTAssertEqual(
            SpacesDeviceAPIAuthentication.recoveryMessage(for: error),
            "This Mac no longer recognizes this device. Open Devices and pair this device again.")
    }

    func testRecoveryMessageMatchesTransportAuthenticationTimeoutProbeFailure() {
        let error = NSError(
            domain: "SpacesDeviceAPIClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "The secure Device API transport could not authenticate."]
        )

        XCTAssertEqual(
            SpacesDeviceAPIAuthentication.recoveryMessage(for: error),
            "This Mac no longer recognizes this device. Open Devices and pair this device again.")
    }

    func testRecoveryMessageIgnoresAvailabilityError() {
        let error = NSError(
            domain: "SpacesDeviceAPIServer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Terminal session 'ABC-123' is not available."])

        XCTAssertNil(SpacesDeviceAPIAuthentication.recoveryMessage(for: error))
    }

    func testRecoveryMessageIgnoresConnectionRefused() {
        XCTAssertNil(SpacesDeviceAPIAuthentication.recoveryMessage(for: NWError.posix(.ECONNREFUSED)))
    }
}
