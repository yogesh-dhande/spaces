import Dispatch
import Foundation
import XCTest

@testable import spacesterminalcore

#if os(macOS)
    /// Covers `ensureRunning`'s handling of a `.handingOff` liveness ping during a daemon's
    /// exec-in-place handoff (issue #188 follow-up): the daemon is alive and mid-handoff, not dead, so
    /// the client must wait for the replacement image instead of racing to spawn a second daemon. It also
    /// covers the sibling shutdown case (issue #325/#334/#341 follow-up): the daemon is alive but no
    /// successor is coming, so `ensureRunning` must not wait for one — `isTransitionalHandoffPing`
    /// rejecting `.shuttingDown` is what keeps it out of the 15s `handoffTransitionTimeout` wait. It must
    /// still wait, bounded by the much shorter `shutdownExitTimeout`, for the outgoing daemon to actually
    /// release `TerminalServiceInstanceLock` before spawning a replacement: spawning while the old process
    /// still holds the lock only produces a competitor whose `SpacesDaemonController.init` collides with
    /// it and exits immediately, and `ensureRunning`'s spawn-poll loop never retries the spawn itself.
    /// That wait is keyed off the instance lock itself, not a ping response, so it also covers a daemon
    /// whose accept source is already cancelled and answers no ping at all while it drains persistence.
    ///
    /// These tests exercise `TerminalService.isTransitionalHandoffPing`, `waitForLivePongThroughTransition`,
    /// and `waitForInstanceLockOwnerToExit` directly rather than the full `ensureRunning`. `ensureRunning`
    /// falls back to spawning a real `spacesd` process (via `resolveExecutableURL`, which can resolve an
    /// actual built binary on a dev machine) once these helpers give up waiting, and a test has no safe way
    /// to guarantee that path is never reached. Testing the helpers in isolation pins the same product
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

        /// The JSON shape `TerminalServiceInstanceLock.acquire` writes (its `LockRecord` is private, so
        /// this test writes the same wire shape directly rather than reaching into that type).
        private struct FakeInstanceLockRecord: Codable { let pid: Int32; let token: String }

        private func writeFakeInstanceLock(pid: Int32, path: String) throws {
            try JSONEncoder().encode(FakeInstanceLockRecord(pid: pid, token: UUID().uuidString)).write(to: URL(fileURLWithPath: path))
        }

        func testWaitForInstanceLockOwnerToExitReturnsImmediatelyWhenNoLockFileExists() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let lockPath = root.appendingPathComponent("instance.lock").path
            let socketPath = root.appendingPathComponent("service.sock").path

            let start = Date()
            TerminalService.waitForInstanceLockOwnerToExit(socketPath: socketPath, lockPath: lockPath)
            XCTAssertLessThan(
                Date().timeIntervalSince(start), 1, "an absent lock file names no owner, so there is nothing to wait for")
        }

        /// Reproduces the half of the gate that must NOT wait: a lock file naming a pid that has already
        /// exited is stale, not a live owner, so `TerminalServiceInstanceLock.activeOwnerProcessID` reports
        /// no owner and the gate must return immediately rather than paying the full `shutdownExitTimeout`.
        func testWaitForInstanceLockOwnerToExitReturnsImmediatelyWhenOwnerIsAlreadyDead() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let lockPath = root.appendingPathComponent("instance.lock").path
            let socketPath = root.appendingPathComponent("service.sock").path

            // Spawn and reap a child so its pid is guaranteed dead (not merely unlikely to be reused).
            let deadProcess = Process()
            deadProcess.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try deadProcess.run()
            deadProcess.waitUntilExit()

            try writeFakeInstanceLock(pid: deadProcess.processIdentifier, path: lockPath)

            let start = Date()
            TerminalService.waitForInstanceLockOwnerToExit(socketPath: socketPath, lockPath: lockPath)
            XCTAssertLessThan(
                Date().timeIntervalSince(start), 1, "a dead owner pid must not incur the full shutdownExitTimeout wait")
        }

        /// Reproduces the bug this gate exists to fix (P1 follow-up to #325/#334): a live instance-lock
        /// owner is not proof the daemon is reachable — its accept source may already be cancelled and
        /// answering no ping at all while it drains persistence, so this gate must not depend on a ping
        /// response the daemon might never send. It reads the lock directly and waits for the owner pid
        /// itself to exit, standing in for the outgoing daemon's real exit rather than anything it says.
        func testWaitForInstanceLockOwnerToExitWaitsForALiveOwnerToExit() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let lockPath = root.appendingPathComponent("instance.lock").path
            // No server ever listens here: `waitForServiceExit`'s socket half of its dual gate treats a
            // nonexistent path as an instant "not answering", isolating this test to the pid-liveness half.
            let socketPath = root.appendingPathComponent("service.sock").path

            let liveProcess = Process()
            liveProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
            liveProcess.arguments = ["60"]
            try liveProcess.run()
            defer { if liveProcess.isRunning { liveProcess.terminate() } }

            try writeFakeInstanceLock(pid: liveProcess.processIdentifier, path: lockPath)

            let expectation = XCTestExpectation(description: "waitForInstanceLockOwnerToExit returns once the owner exits")
            nonisolated(unsafe) var elapsed: TimeInterval = 0
            let start = Date()
            DispatchQueue.global().async {
                TerminalService.waitForInstanceLockOwnerToExit(socketPath: socketPath, lockPath: lockPath)
                elapsed = Date().timeIntervalSince(start)
                expectation.fulfill()
            }

            // The lock is already written with the live pid, so it is safe to end the process immediately:
            // the background wait above either observes it still alive on its first poll and catches the
            // exit on a subsequent one, or observes it already gone — either way it must not block past
            // `shutdownExitTimeout`, which the `wait(timeout:)` bound below enforces.
            liveProcess.terminate()
            liveProcess.waitUntilExit()

            wait(for: [expectation], timeout: 5)
            XCTAssertLessThan(
                elapsed, 3, "must return once the owner actually exits, not wait out the full shutdownExitTimeout")
        }
    }
#endif
