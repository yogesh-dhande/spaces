import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore

#if os(macOS)
    /// Covers `ensureRunning`'s handling of a `.handingOff` liveness ping during a daemon's
    /// exec-in-place handoff (issue #188 follow-up): the daemon is alive and mid-handoff, not dead, so
    /// the client must wait for the replacement image instead of racing to spawn a second daemon. It also
    /// covers the sibling `.shuttingDown` case (issue #325/#334 follow-up): the daemon is alive but no
    /// successor is coming, so the client must NOT wait — `ensureRunning`'s only gate on the 15s
    /// `handoffTransitionTimeout` wait is `isTransitionalHandoffPing`, so proving that predicate rejects
    /// `.shuttingDown` is a direct, deterministic proxy for "ensureRunning does not take the 15s wait on a
    /// shutdown" without needing to race a real timeout.
    ///
    /// These tests exercise `TerminalService.isTransitionalHandoffPing` and
    /// `TerminalService.waitForLivePongThroughTransition` directly against a real `TerminalServiceServer`
    /// rather than the full `ensureRunning`. `ensureRunning` falls back to spawning a real `spacesd`
    /// process (via `resolveExecutableURL`, which can resolve an actual built binary on a dev machine)
    /// whenever the transitional wait fails to observe a live pong in time, and a test has no safe way to
    /// guarantee that path is never reached. Testing the helper in isolation pins the same product
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
    }
#endif
