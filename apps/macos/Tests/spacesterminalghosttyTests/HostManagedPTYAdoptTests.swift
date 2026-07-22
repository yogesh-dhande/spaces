import Foundation
import XCTest

@testable import spacesterminalcore
@testable import spacesterminalghostty

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Thread-safe accumulator for the driver's `@Sendable` output handler.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var string: String { String(decoding: snapshot, as: UTF8.self) }
}

/// Exercises the exec-in-place handoff surface of `HostManagedPTYTerminalSessionDriver`:
/// buffering + file-append output capture on the source driver, and adoption of an
/// inherited PTY master fd + child pid on the destination driver without forking.
final class HostManagedPTYAdoptTests: XCTestCase {
    private let fastEscalation = HostManagedPTYTerminalSessionDriver.TerminationEscalationIntervals(hupGrace: 0.2, termGrace: 0.5, killGrace: 0.5)

    private func makeConfiguration(sessionID: String, command: String?) -> TerminalSessionLaunchConfiguration {
        TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: "handoff-test", workingDirectory: "/tmp", shell: "/bin/zsh", command: command,
            createdAt: "2026-07-12T00:00:00Z", workspaceID: "workspace-handoff", kind: .shell)
    }

    private func makeTemporaryFilePath() -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("host-managed-pty-adopt-\(UUID().uuidString).log").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: nil))
        return path
    }

    @discardableResult private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }

    private func fileByteCount(_ path: String) -> Int { (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0 }

    private func beginHandoffOutputBuffering(_ driver: HostManagedPTYTerminalSessionDriver?) {
        guard let driver else { return XCTFail("missing PTY driver") }
        let completed = DispatchSemaphore(value: 0)
        Task {
            await driver.beginHandoffOutputBuffering()
            completed.signal()
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success, "handoff buffering did not finish")
    }

    // MARK: - Non-blocking terminate()

    /// Regression for the daemon main-actor offload: `terminate()` runs on the terminal engine executor,
    /// so it must never block on `close(master)` (which hangs until the PTY reader unblocks) or `waitpid`.
    /// With a child that keeps the PTY slave open (the read loop is blocked in `read()`), terminate()
    /// returns immediately and the child is reaped + the fd closed shortly after via the escalation ladder
    /// and the read loop's deferred close.
    func testTerminateReturnsPromptlyAndReapsChildHoldingPTYSlaveOpen() throws {
        let driver = HostManagedPTYTerminalSessionDriver(
            launchConfiguration: makeConfiguration(sessionID: "terminate-live-child", command: "cat"),
            terminationEscalationIntervals: fastEscalation)
        try driver.startIfNeeded()
        XCTAssertTrue(waitUntil { driver.childPID() != nil }, "child never came up")
        let childPID = try XCTUnwrap(driver.childPID())

        // terminate() does only bookkeeping + SIGHUP + a detached escalation, so it returns well under any
        // grace period — the pre-fix inline blocking close(master) would hang here indefinitely.
        let start = Date()
        driver.terminate()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.2, "terminate() blocked for \(elapsed)s instead of deferring the PTY teardown")

        // The child is reaped (kill reports ESRCH, i.e. the pid is fully gone, not a lingering zombie) and
        // the driver drops it shortly after, driven by the escalation + the read loop's fd close.
        XCTAssertTrue(waitUntil(timeout: 10) { kill(childPID, 0) != 0 && errno == ESRCH }, "child was not reaped after terminate()")
        XCTAssertTrue(waitUntil(timeout: 10) { driver.childPID() == nil }, "driver still reports a live child after teardown")
    }

    /// Regression for the PTY escalation gap: reaping the leader is not enough to unblock the read loop.
    /// The leader shell spawns a background descendant that ignores SIGHUP and keeps the PTY slave open,
    /// then exits immediately. The reader stays blocked while that descendant lives, so terminate()'s
    /// escalation must continue past the (already-reaped) leader to the process group (SIGTERM/SIGKILL)
    /// until the reader actually reaches EOF — otherwise the master fd and the driver leak forever and the
    /// closed handler never fires.
    func testTerminateEscalatesPastReapedLeaderUntilSurvivingDescendantReleasesPTYSlave() throws {
        // The subshell inherits the leader's PTY slave on fds 0/1/2; `trap '' HUP` sets SIG_IGN for SIGHUP
        // (preserved across the `exec`), so the descendant survives the group SIGHUP and keeps the slave open
        // after the leader exits.
        let command = "(trap '' HUP; exec sleep 30) & exit 0"
        let driver = HostManagedPTYTerminalSessionDriver(
            launchConfiguration: makeConfiguration(sessionID: "terminate-survivor", command: command),
            terminationEscalationIntervals: fastEscalation)
        let closedExpectation = expectation(description: "reader reaches EOF and the closed handler fires")
        driver.setSessionClosedHandler { closedExpectation.fulfill() }
        try driver.startIfNeeded()
        XCTAssertTrue(waitUntil { driver.childPID() != nil }, "child never came up")
        let childPID = try XCTUnwrap(driver.childPID())

        // Let the leader spawn the descendant and exit on its own; the read loop stays blocked because the
        // descendant still holds the slave, so the leader is an unreaped zombie awaiting terminate().
        usleep(200_000)

        let start = Date()
        driver.terminate()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2, "terminate() blocked instead of deferring teardown")

        // Escalation must reap the leader AND drive the SIGHUP-immune descendant dead via the group signal so
        // read() returns EOF: the closed handler fires and the driver drops the child within the bounded ladder.
        wait(for: [closedExpectation], timeout: 10)
        XCTAssertTrue(waitUntil(timeout: 10) { kill(childPID, 0) != 0 && errno == ESRCH }, "leader was not reaped after terminate()")
        XCTAssertTrue(waitUntil(timeout: 10) { driver.childPID() == nil }, "driver still reports a live child after teardown")
    }

    // MARK: - Adopt round-trip

    func testAdoptRoundTripHandsOffLiveChild() throws {
        let configuration = makeConfiguration(sessionID: "roundtrip", command: "cat")
        var driverA: HostManagedPTYTerminalSessionDriver? = HostManagedPTYTerminalSessionDriver(
            launchConfiguration: configuration, terminationEscalationIntervals: fastEscalation)
        let collectorA = OutputCollector()
        driverA?.setOutputHandler { collectorA.append($0) }
        try driverA?.startIfNeeded()

        // The child echoes through driver A before the handoff begins.
        driverA?.sendRawBytes(Data("ping\n".utf8))
        XCTAssertTrue(waitUntil { collectorA.string.contains("ping") }, "driver A never observed its child echo")

        // Stage the handoff: buffer, flush to a file, then snapshot the descriptors.
        beginHandoffOutputBuffering(driverA)
        let filePath = makeTemporaryFilePath()
        try driverA?.finishHandoffOutputBuffering(appendingTo: filePath)
        guard let snapshot = driverA?.handoffDescriptorSnapshot() else { return XCTFail("driver A produced no handoff descriptor snapshot") }
        XCTAssertGreaterThanOrEqual(snapshot.masterFD, 0)
        XCTAssertGreaterThan(snapshot.childPID, 0)

        // Stand in for execv destroying driver A's read thread while the master fd
        // survives. Closing A's descriptor from this thread does not reliably interrupt
        // its blocking read while the duplicate keeps the PTY open. Make the shared open
        // file description nonblocking, wake the reader through the child, and wait for
        // A's loop to retire before restoring blocking mode for B. The real handoff does
        // not need this coordination because exec atomically removes the source thread.
        let adoptedFD = dup(snapshot.masterFD)
        XCTAssertGreaterThanOrEqual(adoptedFD, 0)
        let descriptorFlags = fcntl(snapshot.masterFD, F_GETFL)
        XCTAssertGreaterThanOrEqual(descriptorFlags, 0)
        XCTAssertEqual(fcntl(snapshot.masterFD, F_SETFL, descriptorFlags | O_NONBLOCK), 0)
        driverA?.sendRawBytes(Data("handoff-wake\n".utf8))
        XCTAssertTrue(waitUntil { driverA?.handoffDescriptorSnapshot() == nil }, "driver A's read loop did not retire for adoption")
        XCTAssertEqual(fcntl(adoptedFD, F_SETFL, descriptorFlags), 0)
        driverA = nil

        // The child must still be alive for driver B to adopt it.
        XCTAssertEqual(kill(snapshot.childPID, 0), 0, "dropping driver A killed the child before adoption")

        let driverB = HostManagedPTYTerminalSessionDriver(launchConfiguration: configuration, terminationEscalationIntervals: fastEscalation)
        let collectorB = OutputCollector()
        driverB.setOutputHandler { collectorB.append($0) }
        driverB.adopt(masterFD: adoptedFD, childPID: snapshot.childPID)

        // Input flows through driver B and the same child echoes it back.
        driverB.sendRawBytes(Data("pong\n".utf8))
        XCTAssertTrue(waitUntil { collectorB.string.contains("pong") }, "driver B never observed output from the adopted child")

        // Resize works through the adopted descriptor.
        XCTAssertTrue(driverB.resizeCellGrid(columns: 100, rows: 40))

        // terminate() reaps the child; the same process was always the parent.
        driverB.terminate()
        XCTAssertTrue(waitUntil { kill(snapshot.childPID, 0) == -1 && errno == ESRCH }, "driver B did not reap the adopted child")
    }

    // MARK: - Ordering across the swap

    func testOutputOrderingAcrossHandoffSwap() throws {
        let command = "for i in $(seq 1 200); do printf 'L%04d\\n' \"$i\"; if [ $((i % 20)) -eq 0 ]; then sleep 0.02; fi; done"
        let configuration = makeConfiguration(sessionID: "ordering", command: command)
        let driver = HostManagedPTYTerminalSessionDriver(launchConfiguration: configuration, terminationEscalationIntervals: fastEscalation)
        let handlerCollector = OutputCollector()
        driver.setOutputHandler { handlerCollector.append($0) }

        let closedExpectation = expectation(description: "child exit fires the closed handler")
        driver.setSessionClosedHandler { closedExpectation.fulfill() }
        try driver.startIfNeeded()

        // Flip mid-stream: wait until the handler has captured some early lines, then
        // swap to buffering and immediately to the append-only file sink.
        XCTAssertTrue(waitUntil { handlerCollector.string.contains("L0010") }, "no early output captured before the swap")
        beginHandoffOutputBuffering(driver)
        let filePath = makeTemporaryFilePath()
        try driver.finishHandoffOutputBuffering(appendingTo: filePath)

        wait(for: [closedExpectation], timeout: 10)

        // Concatenate handler bytes (pre-swap) then file bytes (buffered + direct) and
        // assert every numbered line appears exactly once, in order, with no gaps.
        let fileData = (try? Data(contentsOf: URL(fileURLWithPath: filePath))) ?? Data()
        let combined = handlerCollector.snapshot + fileData
        let text = String(decoding: combined, as: UTF8.self)
        // The PTY emits CRLF line endings, which Swift treats as a single `Character`,
        // so split on `isNewline` (which matches the CRLF grapheme) rather than on a
        // bare "\n"/"\r".
        let rawLines: [String] = text.split(whereSeparator: \.isNewline).map(String.init)
        let markers: [String] = rawLines.filter { line in
            guard line.count == 5, line.first == "L" else { return false }
            return line.dropFirst().allSatisfy(\.isNumber)
        }
        let expected: [String] = (1...200).map { String(format: "L%04d", $0) }
        XCTAssertEqual(markers, expected, "output was lost, duplicated, or reordered across the handoff swap")
    }

    func testHandoffBufferingWaitsForInFlightHandlerDelivery() throws {
        let configuration = makeConfiguration(sessionID: "handler-barrier", command: "printf barrier-ready")
        let driver = HostManagedPTYTerminalSessionDriver(launchConfiguration: configuration, terminationEscalationIntervals: fastEscalation)
        let handlerEntered = expectation(description: "output handler entered")
        let sessionClosed = expectation(description: "short-lived child exited")
        let releaseHandler = DispatchSemaphore(value: 0)
        let bufferingReturned = DispatchSemaphore(value: 0)
        driver.setOutputHandler { _ in
            handlerEntered.fulfill()
            releaseHandler.wait()
        }
        driver.setSessionClosedHandler { sessionClosed.fulfill() }
        try driver.startIfNeeded()

        wait(for: [handlerEntered], timeout: 5)
        Task {
            await driver.beginHandoffOutputBuffering()
            bufferingReturned.signal()
        }

        XCTAssertEqual(
            bufferingReturned.wait(timeout: .now() + 0.1), .timedOut, "buffering must not return while a pre-swap handler delivery is still running")
        releaseHandler.signal()
        XCTAssertEqual(bufferingReturned.wait(timeout: .now() + 5), .success)
        wait(for: [sessionClosed], timeout: 5)
    }

    // MARK: - Dead-child adopt

    func testAdoptDeadChildFiresTerminationPath() throws {
        // A valid PTY master whose slave has been closed reads EOF immediately.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        XCTAssertGreaterThanOrEqual(master, 0)
        XCTAssertEqual(grantpt(master), 0)
        XCTAssertEqual(unlockpt(master), 0)
        guard let slaveNameC = ptsname(master) else { return XCTFail("ptsname failed for the PTY master") }
        let slave = open(String(cString: slaveNameC), O_RDWR | O_NOCTTY)
        XCTAssertGreaterThanOrEqual(slave, 0)

        // A child that already exited and was reaped stands in for a session whose
        // child died mid-handoff-window.
        let reapedProcess = Process()
        reapedProcess.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try reapedProcess.run()
        reapedProcess.waitUntilExit()
        let deadPID = reapedProcess.processIdentifier
        XCTAssertGreaterThan(deadPID, 0)

        // Closing the only slave fd drops the master to EOF.
        close(slave)

        let driver = HostManagedPTYTerminalSessionDriver(
            launchConfiguration: makeConfiguration(sessionID: "dead-child", command: "cat"), terminationEscalationIntervals: fastEscalation)
        let closedExpectation = expectation(description: "adopting a dead-child session fires the closed handler")
        driver.setSessionClosedHandler { closedExpectation.fulfill() }
        driver.adopt(masterFD: master, childPID: deadPID)

        wait(for: [closedExpectation], timeout: 5)
        XCTAssertNil(driver.childPID(), "the adopted session should report no live child after the termination path")
    }

    // MARK: - endHandoffOutputBuffering restore

    func testEndHandoffOutputBufferingRestoresHandlerDelivery() throws {
        let configuration = makeConfiguration(sessionID: "restore", command: "cat")
        let driver = HostManagedPTYTerminalSessionDriver(launchConfiguration: configuration, terminationEscalationIntervals: fastEscalation)
        let collector = OutputCollector()
        driver.setOutputHandler { collector.append($0) }
        try driver.startIfNeeded()

        let filePath = makeTemporaryFilePath()
        defer { try? FileManager.default.removeItem(atPath: filePath) }
        beginHandoffOutputBuffering(driver)
        try driver.finishHandoffOutputBuffering(appendingTo: filePath)
        driver.endHandoffOutputBuffering()

        let byteCountAfterEnd = fileByteCount(filePath)

        // After restore, output flows back through the handler and never to the file.
        driver.sendRawBytes(Data("hello\n".utf8))
        XCTAssertTrue(waitUntil { collector.string.contains("hello") }, "handler delivery did not resume after endHandoffOutputBuffering")
        XCTAssertEqual(fileByteCount(filePath), byteCountAfterEnd, "output leaked to the handoff file after restore")

        driver.terminate()
    }

    func testPauseHandoffOutputStopsFileAppendsUntilFallbackDelivery() throws {
        let configuration = makeConfiguration(sessionID: "pause-fallback", command: "cat")
        let driver = HostManagedPTYTerminalSessionDriver(launchConfiguration: configuration, terminationEscalationIntervals: fastEscalation)
        let collector = OutputCollector()
        driver.setOutputHandler { collector.append($0) }
        try driver.startIfNeeded()

        let filePath = makeTemporaryFilePath()
        defer { try? FileManager.default.removeItem(atPath: filePath) }
        beginHandoffOutputBuffering(driver)
        try driver.finishHandoffOutputBuffering(appendingTo: filePath)
        driver.pauseHandoffOutputForFallback()
        let byteCountAfterPause = fileByteCount(filePath)

        let marker = "buffered-after-direct-writer-stop"
        driver.sendRawBytes(Data("\(marker)\n".utf8))
        usleep(100_000)
        XCTAssertEqual(
            fileByteCount(filePath), byteCountAfterPause, "the stopped direct writer must not append while the normal handle is positioned")
        XCTAssertFalse(collector.string.contains(marker))

        driver.endHandoffOutputBuffering()
        XCTAssertTrue(waitUntil { collector.string.contains(marker) }, "fallback must deliver bytes buffered after the direct writer stopped")
        driver.terminate()
    }

    func testFailedHandoffFileOpenRestoresBufferedOutputToHandler() throws {
        let configuration = makeConfiguration(sessionID: "restore-buffer", command: "cat")
        let driver = HostManagedPTYTerminalSessionDriver(launchConfiguration: configuration, terminationEscalationIntervals: fastEscalation)
        let collector = OutputCollector()
        driver.setOutputHandler { collector.append($0) }
        try driver.startIfNeeded()

        beginHandoffOutputBuffering(driver)
        driver.sendRawBytes(Data("buffered-before-failure\n".utf8))
        usleep(100_000)
        XCTAssertFalse(collector.string.contains("buffered-before-failure"), "buffered output must not reach the normal handler before fallback")

        let invalidPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: invalidPath, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: invalidPath) }
        XCTAssertThrowsError(try driver.finishHandoffOutputBuffering(appendingTo: invalidPath.path))

        driver.endHandoffOutputBuffering()
        XCTAssertTrue(
            waitUntil { collector.string.contains("buffered-before-failure") },
            "bytes buffered before the persistence failure must return to normal delivery")
        driver.terminate()
    }

    func testDirectHandoffWriteFailureAbortsExecAndRestoresOutputToHandler() throws {
        let configuration = makeConfiguration(sessionID: "direct-write-failure", command: "cat")
        let driver = HostManagedPTYTerminalSessionDriver(
            launchConfiguration: configuration, terminationEscalationIntervals: fastEscalation,
            handoffWriteAction: { _, data in data.isEmpty ? .success(byteCount: 0) : .failure(bytesWritten: 0, errorCode: ENOSPC) })
        let collector = OutputCollector()
        driver.setOutputHandler { collector.append($0) }
        try driver.startIfNeeded()

        let filePath = makeTemporaryFilePath()
        defer { try? FileManager.default.removeItem(atPath: filePath) }
        beginHandoffOutputBuffering(driver)
        try driver.finishHandoffOutputBuffering(appendingTo: filePath)

        let marker = "restore-after-direct-write-failure"
        driver.sendRawBytes(Data("\(marker)\n".utf8))
        XCTAssertTrue(
            waitUntil { (try? driver.withValidatedHandoffOutputForExec {}) == nil },
            "the final exec boundary must surface a direct transcript write failure")

        var reachedExecBoundary = false
        XCTAssertThrowsError(try driver.withValidatedHandoffOutputForExec { reachedExecBoundary = true })
        XCTAssertFalse(reachedExecBoundary)

        driver.endHandoffOutputBuffering()
        XCTAssertTrue(
            waitUntil { collector.string.contains(marker) }, "unwritten direct-sink bytes must return to normal persistence on failed handoff")
        driver.terminate()
    }
}
