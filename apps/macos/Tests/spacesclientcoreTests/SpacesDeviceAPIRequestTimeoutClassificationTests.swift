import Foundation
import XCTest
import spacesdevicecore
import spacesterminalcore

@testable import spacesclientcore

/// `isDeviceAPIRequestTimeout` is the finer classification `DeviceTerminalSessionStateModel.reportFailedInputSend`
/// layers on top of `isDeviceAPITransportFailure` to tell a bare request timeout — the deadline elapsed
/// with no answer, which an app-side stall produces identically to a genuinely dead link — from a
/// connection-level failure that is conclusive proof the link itself is down. See the doc comment on
/// `isDeviceAPIRequestTimeout` for why the distinction exists; this pins the classification itself,
/// independent of how `DeviceTerminalSessionStateModelStreamConnectionTests` exercises it end to end.
final class SpacesDeviceAPIRequestTimeoutClassificationTests: XCTestCase {
    func testTimeoutShapedErrorsClassifyAsRequestTimeouts() {
        // `SpacesDeviceAPIRequestClientError.timeout` is the declared timeout case; `SpacesPinnedTLSConnectionError.timeout`
        // is what the production request path (`sendLine`/`readLine`) actually throws on a deadline —
        // neither `SpacesDeviceAPIRequestClient` nor `SpacesDeviceAPIRequestSessionClient` wraps it into
        // the former, so both shapes must classify identically.
        XCTAssertTrue(SpacesDeviceClient.isDeviceAPIRequestTimeout(SpacesDeviceAPIRequestClientError.timeout("Timed out.")))
        XCTAssertTrue(SpacesDeviceClient.isDeviceAPIRequestTimeout(SpacesPinnedTLSConnectionError.timeout))
    }

    func testConnectionLevelFailuresAreNotRequestTimeouts() {
        // Every other transport failure `isDeviceAPITransportFailure` recognizes is connection-level —
        // the transport itself gave up, not merely a slow round trip — and must not be classified as a
        // bare timeout.
        XCTAssertFalse(SpacesDeviceClient.isDeviceAPIRequestTimeout(SpacesDeviceAPIRequestClientError.emptyResponse))
        XCTAssertFalse(SpacesDeviceClient.isDeviceAPIRequestTimeout(SpacesDeviceAPIRequestClientError.connectionFailed("Connection refused")))
        XCTAssertFalse(SpacesDeviceClient.isDeviceAPIRequestTimeout(SpacesPinnedTLSConnectionError.connectionClosed))
        XCTAssertFalse(SpacesDeviceClient.isDeviceAPIRequestTimeout(SpacesPinnedTLSConnectionError.connectionFailed("refused")))
        XCTAssertFalse(SpacesDeviceClient.isDeviceAPIRequestTimeout(SpacesDeviceEndpointResolverError.allCandidatesUnreachable(hosts: ["1.2.3.4"])))
        XCTAssertFalse(SpacesDeviceClient.isDeviceAPIRequestTimeout(POSIXError(.ETIMEDOUT)))
        XCTAssertFalse(SpacesDeviceClient.isDeviceAPIRequestTimeout(POSIXError(.ECONNRESET)))
    }

    func testNonTransportFailuresAreNotRequestTimeouts() {
        // A reachable daemon's coded rejection is not a transport failure at all, so it is certainly not
        // a request timeout either.
        XCTAssertFalse(
            SpacesDeviceClient.isDeviceAPIRequestTimeout(
                SpacesDeviceAPIRequestClientError.requestRejected(message: "Session is not running.", code: .sessionNotAvailable)))
    }
}
