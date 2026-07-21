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
    }
#endif
