import Foundation
import XCTest
import spacesdeviceapi
import spacesterminalcore

@testable import spacesclientcore

/// `isLocalDaemonUnreachableError` decides whether a `bootstrapLocalDevice` failure degrades the sidebar
/// to offline (a reachability problem) or surfaces as a real error (a persistence/credential failure that
/// happens only after a reachable daemon returns a valid bootstrap).
final class SpacesDeviceClientBootstrapErrorTests: XCTestCase {
    func testControlEndpointUnavailableErrorIsTreatedAsUnreachable() {
        // The control socket is missing/refused — the daemon is unreachable, so degrade to offline.
        XCTAssertTrue(SpacesDeviceClient.isLocalDaemonUnreachableError(POSIXError(.ENOENT)))
        XCTAssertTrue(SpacesDeviceClient.isLocalDaemonUnreachableError(POSIXError(.ECONNREFUSED)))
    }

    func testNetworkTransportConnectionFailureIsTreatedAsUnreachable() {
        // The overview round-trip's Device API network transport couldn't reach the daemon (e.g. timed out).
        // This is the reachability path the overview catch degrades to offline.
        XCTAssertTrue(SpacesDeviceClient.isLocalDaemonUnreachableError(POSIXError(.ETIMEDOUT)))
        XCTAssertTrue(SpacesDeviceClient.isLocalDaemonUnreachableError(POSIXError(.EHOSTUNREACH)))
    }

    func testReachableDaemonOverviewRejectionIsNotTreatedAsUnreachable() {
        // A reachable daemon rejected the overview with a real error (database/migration/authorization,
        // etc.). This must surface, not hide behind the offline sidebar.
        XCTAssertFalse(
            SpacesDeviceClient.isLocalDaemonUnreachableError(
                SpacesDeviceClientError.requestRejected("Overview failed: database disk image is malformed.")))
    }

    func testDeviceAPINotRunningRejectionIsTreatedAsUnreachable() {
        // The daemon answered but its Device API is not running — recoverable, so degrade to offline.
        let error = SpacesDeviceClientError.requestRejected(SpacesDeviceAPIControlClient.deviceAPINotRunningMessage)
        XCTAssertTrue(SpacesDeviceClient.isLocalDaemonUnreachableError(error))
    }

    func testDaemonStartupFailuresAreTreatedAsUnreachable() {
        // spacesd couldn't be brought up — it timed out starting, or its executable is missing — so the
        // local daemon is down and the sidebar degrades to offline. These do not surface as POSIX socket
        // errors, which is the path the offline fallback otherwise misses.
        XCTAssertTrue(SpacesDeviceClient.isLocalDaemonUnreachableError(TerminalServiceError.serviceStartupTimedOut("/path/to/spacesd")))
        XCTAssertTrue(SpacesDeviceClient.isLocalDaemonUnreachableError(TerminalServiceError.executableNotFound))
        // A generic terminal request failure is not a clear daemon-down signal, so it surfaces as an error.
        XCTAssertFalse(SpacesDeviceClient.isLocalDaemonUnreachableError(TerminalServiceError.requestFailed("boom")))
    }

    func testPersistenceAndCredentialFailuresAreNotTreatedAsUnreachable() {
        // A reachable daemon returned a valid bootstrap, but writing the record / saving credentials failed.
        // These must surface, not hide behind an offline sidebar.
        XCTAssertFalse(
            SpacesDeviceClient.isLocalDaemonUnreachableError(
                SpacesDeviceClientError.requestRejected("Couldn't save the device credential to the Keychain.")))
        XCTAssertFalse(SpacesDeviceClient.isLocalDaemonUnreachableError(SpacesDeviceClientError.missingLocalBootstrap))
        XCTAssertFalse(
            SpacesDeviceClient.isLocalDaemonUnreachableError(
                NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: "database is locked"])))
    }
}
