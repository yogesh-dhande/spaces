import Network
import XCTest
import spacesdevicecore
import spacesterminalcore

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

    func testRecoveryMessageMatchesCertificatePinMismatch() {
        let error = TerminalServiceTLSError.certificatePinMismatch(expected: "SHA256:aa", actual: "SHA256:bb")

        XCTAssertEqual(
            SpacesDeviceAPIAuthentication.recoveryMessage(for: error),
            "This Mac no longer recognizes this device. Open Devices and pair this device again.")
    }

    func testRecoveryMessageMatchesReachablePortSecureTransportFailure() {
        // The iOS client maps a reachable port whose pinned-TLS handshake times out to this text; it must
        // still route into the re-pair recovery flow.
        let error = NSError(
            domain: "SpacesDeviceAPIClientError", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "The secure Device API transport could not authenticate."])

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

    func testIsAuthenticationFailureRecognizesUnauthorizedCode() {
        XCTAssertTrue(SpacesDeviceAPIAuthentication.isAuthenticationFailure(code: .unauthorized))
        XCTAssertFalse(SpacesDeviceAPIAuthentication.isAuthenticationFailure(code: .sessionNotRunning))
        XCTAssertFalse(SpacesDeviceAPIAuthentication.isAuthenticationFailure(code: nil))
    }

    func testRecoveryMessageBranchesOnCodeOverMessageSubstring() {
        // A response that carries a category is authoritative. An unauthorized code triggers recovery,
        // and a non-auth code suppresses it even when the message would otherwise match the substrings.
        struct CodedError: LocalizedError, SpacesDeviceErrorCodeProviding {
            let code: SpacesDeviceErrorCode
            var errorDescription: String? { "unauthorized" }
            var spacesDeviceErrorCode: SpacesDeviceErrorCode? { code }
        }
        XCTAssertEqual(
            SpacesDeviceAPIAuthentication.recoveryMessage(for: CodedError(code: .unauthorized)),
            "This Mac no longer recognizes this device. Open Devices and pair this device again.")
        XCTAssertNil(SpacesDeviceAPIAuthentication.recoveryMessage(for: CodedError(code: .notFound)))
    }
}
