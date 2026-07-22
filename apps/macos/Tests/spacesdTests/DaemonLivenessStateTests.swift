import Foundation
import XCTest

#if os(macOS)
    @testable import spacesd
    @testable import spacesterminalcore

    /// A liveness `.ping` is answered off the main actor from `DaemonLivenessState` so a health probe
    /// stays fast even while the main actor is saturated (issue #188). That fast path must not drift
    /// from `handle(_:)`'s own behavior: while an exec handoff is in progress, `handle(_:)` rejects every
    /// real request with `.shuttingDown`, so the ping must report the same thing rather than "ok" — a
    /// client must never conclude the daemon is available when everything else it asks for is refused.
    final class DaemonLivenessStateTests: XCTestCase {
        func testFreshStatePingsOkWithNoSessions() {
            let state = DaemonLivenessState()

            let response = state.pingResponse()

            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.message, "pong")
            XCTAssertEqual(response.daemonStatus?.activeSessionCount, 0)
        }

        func testPingReflectsStoredSessionCountAndFingerprint() {
            let state = DaemonLivenessState()

            state.storeSessionCount(3)
            state.storeFingerprint("abc")

            let response = state.pingResponse()

            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.daemonStatus?.activeSessionCount, 3)
            XCTAssertEqual(response.daemonStatus?.certificateFingerprint, "abc")
        }

        func testPingRejectsWhileHandoffInProgress() {
            let state = DaemonLivenessState()

            state.storeHandoffInProgress(true)
            let response = state.pingResponse()

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorCode, .shuttingDown)
        }

        func testPingResumesOkOnceHandoffClears() {
            let state = DaemonLivenessState()

            state.storeHandoffInProgress(true)
            state.storeHandoffInProgress(false)
            let response = state.pingResponse()

            XCTAssertTrue(response.ok)
            XCTAssertNil(response.errorCode)
        }

        // Session-CREATE admission. Every create gate (`createSessionOffMain`'s off-actor early-out and the
        // engine-side `createSession`/`startSessionCoreResponse` authority) consults
        // `sessionCreateRejection()`. Distinct from the ping path above: a create must be refused while
        // EITHER an exec handoff or a shutdown is underway. `shutdown()` sets `shutdownInProgress` before it
        // stops shared services and snapshots `sessionCores`, so a `.create` accepted onto the serial work
        // queue just before shutdown — which `server.stop()` does not cancel — cannot spend up to 120s in
        // git prep and then insert a core AFTER the snapshot, one shutdown never terminates or drains and
        // `exit(0)` abandons (a leaked HUP-immune child plus a lingering `.running` row).

        func testFreshStateAdmitsSessionCreate() {
            let state = DaemonLivenessState()

            XCTAssertNil(state.sessionCreateRejection())
        }

        func testSessionCreateRefusedWhileShuttingDown() {
            let state = DaemonLivenessState()

            state.storeShutdownInProgress(true)
            let rejection = state.sessionCreateRejection()

            XCTAssertNotNil(rejection)
            XCTAssertEqual(rejection?.ok, false)
            XCTAssertEqual(rejection?.errorCode, .shuttingDown)
            XCTAssertEqual(rejection?.message, "spacesd is shutting down.")
        }

        func testSessionCreateRefusedWhileHandingOff() {
            let state = DaemonLivenessState()

            state.storeHandoffInProgress(true)
            let rejection = state.sessionCreateRejection()

            XCTAssertNotNil(rejection)
            XCTAssertEqual(rejection?.errorCode, .shuttingDown)
            XCTAssertEqual(rejection?.message, "spacesd is handing off to an updated daemon.")
        }

        func testShutdownFlagIsMonotonicAcrossSnapshots() {
            let state = DaemonLivenessState()

            state.storeShutdownInProgress(true)

            XCTAssertTrue(state.snapshot().shutdownInProgress)
            XCTAssertNotNil(state.sessionCreateRejection())
        }
    }
#endif
