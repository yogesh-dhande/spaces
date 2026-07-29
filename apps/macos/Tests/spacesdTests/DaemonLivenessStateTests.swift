import Foundation
import XCTest

#if os(macOS)
    @testable import spacesd
    @testable import spacesterminalcore

    /// A liveness `.ping` is answered off the main actor from `DaemonLivenessState` so a health probe
    /// stays fast even while the main actor is saturated (issue #188). That fast path must not drift
    /// from `handle(_:)`'s own behavior: while a handoff or a shutdown is in progress, `handle(_:)`
    /// rejects every real request — with `.handingOff` or `.shuttingDown` respectively — so the ping must
    /// report the same code rather than "ok" — a client must never conclude the daemon is available when
    /// everything else it asks for is refused, and must be able to tell the two teardown reasons apart
    /// (see issue #325's follow-up: a client waits out a handoff but must not wait out a shutdown, since
    /// no successor is coming).
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

        /// Before the Device API's bound host is learned (a ping racing daemon startup), the ping must
        /// report "no addresses known" rather than guessing — see `deviceAPIAddresses`'s "empty means
        /// reported nothing" contract.
        func testDeviceAPIAddressesEmptyBeforeBoundHostIsKnown() {
            let state = DaemonLivenessState()

            XCTAssertEqual(state.currentDeviceAPIAddresses(), [])
            XCTAssertEqual(state.pingResponse().daemonStatus?.deviceAPIAddresses, [])
        }

        /// A pinned (non-wildcard) bound host is reported verbatim — same derivation
        /// `SpacesDeviceAPINetworkInterfaces.pairingLinkHosts(boundHost:)` uses for a pairing link, so
        /// this test needs no live-interface enumeration to be deterministic.
        func testDeviceAPIAddressesReflectsPinnedBoundHostVerbatim() {
            let state = DaemonLivenessState()

            state.storeDeviceAPIBoundHost("192.168.1.50")

            XCTAssertEqual(state.currentDeviceAPIAddresses(), ["192.168.1.50"])
            XCTAssertEqual(state.pingResponse().daemonStatus?.deviceAPIAddresses, ["192.168.1.50"])
        }

        /// Clients abbreviate this device's paths against the home the daemon reports, so a status the
        /// daemon builds must carry its own home rather than leaving the reader to substitute one.
        func testPingReportsTheDaemonsOwnHomeDirectory() {
            let state = DaemonLivenessState()

            XCTAssertEqual(state.pingResponse().daemonStatus?.homeDirectory, NSHomeDirectory())
        }

        func testPingRejectsWhileHandoffInProgress() {
            let state = DaemonLivenessState()

            state.storeHandoffInProgress(true)
            let response = state.pingResponse()

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorCode, .handingOff)
        }

        func testPingResumesOkOnceHandoffClears() {
            let state = DaemonLivenessState()

            state.storeHandoffInProgress(true)
            state.storeHandoffInProgress(false)
            let response = state.pingResponse()

            XCTAssertTrue(response.ok)
            XCTAssertNil(response.errorCode)
        }

        /// Regression test for issue #325: `shutdownInProgress` used to feed only the session-create gate,
        /// so a ping sent while the daemon was merely shutting down (not handing off) still reported "ok"
        /// even though `handle(_:)` and every off-main RPC handler had already started refusing every
        /// other command. `pingResponse()` must read the same `teardownRejection()` predicate those guards
        /// consult, so a poller never sees the daemon as live while it is on its way out.
        func testPingRejectsWhileShutdownInProgress() {
            let state = DaemonLivenessState()

            state.storeShutdownInProgress(true)
            let response = state.pingResponse()

            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorCode, .shuttingDown)
            XCTAssertEqual(response.message, "spacesd is shutting down.")
        }

        // General command admission. `teardownRejection()` is consulted by every command gate in the
        // daemon — `handle(_:)`'s first line, every off-main handler (`runWorkspaceCommandOffMain`,
        // `prepareWorkspaceOffMain`, `terminalSendOffMain`, `terminalCommandOffMain`, `agentSpawnOffMain`,
        // `workspaceStartOffMain`, `agentKillOffMain`, `agentSignalOffMain`, `loadTerminalStateOffMain`,
        // `handleTerminalControlOffMain`, `terminateSessionOffMain`, `profileCommandOffMain`), and the
        // session-CREATE family (`createSessionOffMain`/`createSession`/`startSessionCoreResponse`) — so
        // exercising it here stands in for every one of those call sites without needing to stand up the
        // (private) `SpacesDaemonController`. A representative mutating command (session create, exercised
        // directly below) and a representative read command (`.ping`, exercised above) both resolve to
        // this same predicate and must refuse identically while EITHER an exec handoff or a shutdown is
        // underway. For create specifically: `shutdown()` sets `shutdownInProgress` before it stops shared
        // services and snapshots `sessionCores`, so a `.create` accepted onto the serial work queue just
        // before shutdown — which `server.stop()` does not cancel — cannot spend up to 120s in git prep and
        // then insert a core AFTER the snapshot, one shutdown never terminates or drains and `exit(0)`
        // abandons (a leaked HUP-immune child plus a lingering `.running` row).

        func testFreshStateAdmitsEveryCommand() {
            let state = DaemonLivenessState()

            XCTAssertNil(state.teardownRejection())
        }

        func testCommandsRefusedWhileShuttingDown() {
            let state = DaemonLivenessState()

            state.storeShutdownInProgress(true)
            let rejection = state.teardownRejection()

            XCTAssertNotNil(rejection)
            XCTAssertEqual(rejection?.ok, false)
            XCTAssertEqual(rejection?.errorCode, .shuttingDown)
            XCTAssertEqual(rejection?.message, "spacesd is shutting down.")
        }

        func testCommandsRefusedWhileHandingOff() {
            let state = DaemonLivenessState()

            state.storeHandoffInProgress(true)
            let rejection = state.teardownRejection()

            XCTAssertNotNil(rejection)
            XCTAssertEqual(rejection?.errorCode, .handingOff)
            XCTAssertEqual(rejection?.message, "spacesd is handing off to an updated daemon.")
        }

        /// Issue #325's follow-up: the two teardown latches must produce distinct wire codes, because a
        /// waiting client (`TerminalService.ensureRunning`) treats them oppositely — it waits out a
        /// handoff (a successor is coming) but must spawn immediately on a shutdown (nothing is coming).
        /// Sharing one code, as both latches did before this test existed, would silently reintroduce the
        /// 15s stall issue #334 flags for a plain shutdown.
        func testShutdownAndHandoffProduceDistinctErrorCodes() {
            let shuttingDownState = DaemonLivenessState()
            shuttingDownState.storeShutdownInProgress(true)

            let handingOffState = DaemonLivenessState()
            handingOffState.storeHandoffInProgress(true)

            let shutdownCode = shuttingDownState.teardownRejection()?.errorCode
            let handoffCode = handingOffState.teardownRejection()?.errorCode

            XCTAssertEqual(shutdownCode, .shuttingDown)
            XCTAssertEqual(handoffCode, .handingOff)
            XCTAssertNotEqual(shutdownCode, handoffCode)
        }

        func testShutdownFlagIsMonotonicAcrossSnapshots() {
            let state = DaemonLivenessState()

            state.storeShutdownInProgress(true)

            XCTAssertTrue(state.snapshot().shutdownInProgress)
            XCTAssertNotNil(state.teardownRejection())
        }
    }
#endif
