import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore

#if os(macOS)
    /// Covers `ensureRunning`'s handling of a `.handingOff` liveness ping during a daemon's
    /// exec-in-place handoff (issue #188 follow-up): the daemon is alive and mid-handoff, not dead, so
    /// the client must wait for the replacement image instead of racing to spawn a second daemon. It also
    /// covers the sibling `.shuttingDown` case (issue #325/#334 follow-up): the daemon is alive but no
    /// successor is coming, so `ensureRunning` must not wait for one — `isTransitionalHandoffPing`
    /// rejecting `.shuttingDown` is what keeps it out of the 15s `handoffTransitionTimeout` wait. It must
    /// still wait, bounded by the much shorter `shutdownExitTimeout`, for the outgoing daemon to actually
    /// release `TerminalServiceInstanceLock` before spawning a replacement: spawning while the old process
    /// still holds the lock only produces a competitor whose `SpacesDaemonController.init` collides with
    /// it and exits immediately, and `ensureRunning`'s spawn-poll loop never retries the spawn itself.
    ///
    /// These tests exercise `TerminalService.isTransitionalHandoffPing`, `isShuttingDownPing`,
    /// `waitForLivePongThroughTransition`, and `waitForShuttingDownServiceExit` directly against a real
    /// `TerminalServiceServer` rather than the full `ensureRunning`. `ensureRunning` falls back to
    /// spawning a real `spacesd` process (via `resolveExecutableURL`, which can resolve an actual built
    /// binary on a dev machine) once these helpers give up waiting, and a test has no safe way to
    /// guarantee that path is never reached. Testing the helpers in isolation pins the same product
    /// contract without any risk of a test launching a real daemon.
    final class TerminalServiceEnsureRunningTests: XCTestCase {
        func testIsTransitionalHandoffPingOnlyMatchesHandoffCode() {
            let live = TerminalServiceResponse(ok: true, message: "pong")
            let handingOff = TerminalServiceResponse(ok: false, message: "spacesd is handing off to an updated daemon.", errorCode: .handingOff)
            let shuttingDown = TerminalServiceResponse(ok: false, message: "spacesd is shutting down.", errorCode: .shuttingDown)
            let otherFailure = TerminalServiceResponse(ok: false, message: "spacesd is shutting down.", errorCode: .internalError)
            let noErrorCode = TerminalServiceResponse(ok: false, message: "connection reset")

            XCTAssertFalse(TerminalService.isTransitionalHandoffPing(live))
            XCTAssertTrue(TerminalService.isTransitionalHandoffPing(handingOff))
            // The headline case: a shutdown is a live answer too, but carries no promise of a successor,
            // so it must NOT be treated as transitional — this is what keeps `ensureRunning` from stalling
            // out the full 15s `handoffTransitionTimeout` waiting for a daemon that isn't coming back.
            XCTAssertFalse(TerminalService.isTransitionalHandoffPing(shuttingDown))
            XCTAssertFalse(TerminalService.isTransitionalHandoffPing(otherFailure))
            XCTAssertFalse(TerminalService.isTransitionalHandoffPing(noErrorCode))
        }

        func testWaitForLivePongThroughTransitionWaitsOutHandoffThenAdopts() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let socketPath = root.appendingPathComponent("service.sock").path
            let queue = DispatchQueue(label: "terminal-service-ensure-running-test")

            // Deterministic wall-clock transition: the server answers the handoff rejection until
            // `transitionEndsAt`, then answers a live pong — standing in for the old image's socket
            // going quiet mid-exec and the new image rebinding it moments later.
            let transitionEndsAt = Date().addingTimeInterval(0.6)
            let server = TerminalServiceServer(
                socketPath: socketPath, queue: queue,
                livenessResponder: {
                    if Date() < transitionEndsAt {
                        return TerminalServiceResponse(
                            ok: false, message: "spacesd is handing off to an updated daemon.", errorCode: .handingOff, servicePID: 111)
                    }
                    return TerminalServiceResponse(ok: true, message: "pong", servicePID: 222)
                }
            ) { _ in TerminalServiceResponse(ok: false, message: "unexpected non-ping request") }
            try server.start()
            defer { server.stop() }

            // Confirm the transitional window is actually observed before the live pong lands, so this
            // test would fail if the helper adopted the rejection instead of waiting past it.
            let firstPing = try TerminalServiceClient.send(request: TerminalServiceRequest(command: .ping), socketPath: socketPath, timeout: 1)
            XCTAssertFalse(firstPing.ok)
            XCTAssertTrue(TerminalService.isTransitionalHandoffPing(firstPing))

            let start = Date()
            let liveResponse = TerminalService.waitForLivePongThroughTransition(socketPath: socketPath)
            let elapsed = Date().timeIntervalSince(start)

            XCTAssertEqual(liveResponse, TerminalServiceResponse(ok: true, message: "pong", servicePID: 222))
            XCTAssertGreaterThan(elapsed, 0.2, "The helper must wait through the transitional window rather than giving up immediately")
            XCTAssertLessThan(elapsed, 5, "The helper must adopt promptly once the replacement image answers, not wait out the full timeout")
        }

        func testIsShuttingDownPingOnlyMatchesShuttingDownCode() {
            let live = TerminalServiceResponse(ok: true, message: "pong")
            let handingOff = TerminalServiceResponse(ok: false, message: "spacesd is handing off to an updated daemon.", errorCode: .handingOff)
            let shuttingDown = TerminalServiceResponse(ok: false, message: "spacesd is shutting down.", errorCode: .shuttingDown)
            let otherFailure = TerminalServiceResponse(ok: false, message: "spacesd is shutting down.", errorCode: .internalError)
            let noErrorCode = TerminalServiceResponse(ok: false, message: "connection reset")

            XCTAssertFalse(TerminalService.isShuttingDownPing(live))
            XCTAssertFalse(TerminalService.isShuttingDownPing(handingOff))
            XCTAssertTrue(TerminalService.isShuttingDownPing(shuttingDown))
            XCTAssertFalse(TerminalService.isShuttingDownPing(otherFailure))
            XCTAssertFalse(TerminalService.isShuttingDownPing(noErrorCode))
        }

        /// Reproduces the bug `waitForShuttingDownServiceExit` exists to fix: a `.shuttingDown` rejection
        /// is not proof the daemon is gone — the outgoing daemon keeps answering pings with that same
        /// rejection right up until it actually exits (`DaemonLivenessState.teardownRejection()` answers
        /// every ping this way while `shutdownInProgress` is set). If `ensureRunning` treated the
        /// rejection itself as "gone" and spawned immediately, the replacement would collide with the
        /// still-live instance lock and die before ever binding the socket. This proves the helper instead
        /// waits for the socket to stop answering ANY ping at all — standing in for the process actually
        /// exiting — before returning.
        func testWaitForShuttingDownServiceExitWaitsForTheSocketToStopAnsweringEntirely() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let socketPath = root.appendingPathComponent("service.sock").path
            let queue = DispatchQueue(label: "terminal-service-ensure-running-shutdown-test")

            // `servicePID: 0` is a sentinel `isProcessAlive` always reports dead (it rejects pid <= 0
            // outright), so the only thing that can make the helper report "gone" here is the socket
            // itself going silent — exactly the behavior under test.
            //
            // `nonisolated(unsafe)`: `server.stop()` below is called from a background queue to
            // simulate the outgoing daemon's real exit. `TerminalServiceServer` is not `Sendable`, but
            // `stop()` only cancels a dispatch source and clears a reference — safe to call from any
            // thread, and already done that way by every other test in this file via `defer`.
            nonisolated(unsafe) let server = TerminalServiceServer(
                socketPath: socketPath, queue: queue,
                livenessResponder: { TerminalServiceResponse(ok: false, message: "spacesd is shutting down.", errorCode: .shuttingDown, servicePID: 0) }
            ) { _ in TerminalServiceResponse(ok: false, message: "unexpected non-ping request") }
            try server.start()
            defer { server.stop() }

            // Confirm the rejection is actually being served before timing the wait, so this test fails
            // loudly (rather than trivially passing) if the fake server never came up.
            let firstPing = try TerminalServiceClient.send(request: TerminalServiceRequest(command: .ping), socketPath: socketPath, timeout: 1)
            XCTAssertFalse(firstPing.ok)
            XCTAssertTrue(TerminalService.isShuttingDownPing(firstPing))

            // Simulate the outgoing daemon's real exit: stop answering entirely after a delay, standing
            // in for the moment its process actually terminates rather than merely having announced it.
            let stopDelay = 0.3
            DispatchQueue.global().asyncAfter(deadline: .now() + stopDelay) { server.stop() }

            let start = Date()
            TerminalService.waitForShuttingDownServiceExit(socketPath: socketPath, rejection: firstPing)
            let elapsed = Date().timeIntervalSince(start)

            XCTAssertGreaterThan(
                elapsed, stopDelay - 0.1,
                "The helper must wait for the outgoing daemon to actually stop answering, not return as soon as it sees a .shuttingDown rejection")
            XCTAssertLessThan(
                elapsed, 3, "The helper must return promptly once the daemon is actually gone rather than waiting out the full shutdownExitTimeout")
        }
    }
#endif
