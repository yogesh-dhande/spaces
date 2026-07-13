import Foundation
import XCTest

@testable import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class DaemonHandoffTests: XCTestCase {
    private var originalEnvironment: [(String, String?)] = []

    override func setUp() {
        super.setUp()
        let keys = [SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable]
        originalEnvironment = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
    }

    override func tearDown() {
        for (name, value) in originalEnvironment { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
        SpacesProfile.resetCacheForTesting()
        originalEnvironment = []
        super.tearDown()
    }

    /// Points `TerminalServicePaths` at an isolated, per-test profile root so
    /// `DaemonHandoffStore` reads/writes never touch a real profile's handoff table.
    private func useIsolatedProfile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv(SpacesProfile.databasePathEnvironmentVariable, root.appendingPathComponent("spaces.db").path, 1)
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        SpacesProfile.resetCacheForTesting()
        return root
    }

    // MARK: - write / consume round trip

    func testWriteConsumeRoundTripPreservesAllFieldsAndDeletesFile() throws {
        let root = try useIsolatedProfile()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = DaemonHandoffSessionRecord(
            sessionID: "session-1", masterFD: 42, childPID: 4242, columns: 120, rows: 40, ownerEpoch: 7, screenStateRevision: 99, appearance: "dark")
        let table = DaemonHandoffTable(
            formatVersion: DaemonHandoffTable.currentFormatVersion, generation: 1, pid: getpid(), sourceVersion: "1.2.3",
            writtenAt: "2026-07-12T00:00:00.000Z", sessions: [session])

        try DaemonHandoffStore.write(table)
        let path = try TerminalServicePaths.daemonHandoffTablePath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let consumed = try XCTUnwrap(DaemonHandoffStore.consume())
        XCTAssertEqual(consumed.formatVersion, table.formatVersion)
        XCTAssertEqual(consumed.generation, table.generation)
        XCTAssertEqual(consumed.pid, table.pid)
        XCTAssertEqual(consumed.sourceVersion, table.sourceVersion)
        XCTAssertEqual(consumed.writtenAt, table.writtenAt)
        XCTAssertEqual(consumed.sessions.count, 1)
        let consumedSession = try XCTUnwrap(consumed.sessions.first)
        XCTAssertEqual(consumedSession.sessionID, session.sessionID)
        XCTAssertEqual(consumedSession.masterFD, session.masterFD)
        XCTAssertEqual(consumedSession.childPID, session.childPID)
        XCTAssertEqual(consumedSession.columns, session.columns)
        XCTAssertEqual(consumedSession.rows, session.rows)
        XCTAssertEqual(consumedSession.ownerEpoch, session.ownerEpoch)
        XCTAssertEqual(consumedSession.screenStateRevision, session.screenStateRevision)
        XCTAssertEqual(consumedSession.appearance, session.appearance)

        // Consume deletes the table whether or not it was adoptable.
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testConsumeReturnsNilAndDeletesWhenNoTableIsPresent() throws {
        _ = try useIsolatedProfile()
        XCTAssertNil(DaemonHandoffStore.consume())
    }

    func testConsumeReturnsNilAndDeletesWhenPidDoesNotMatchCurrentProcess() throws {
        let root = try useIsolatedProfile()
        defer { try? FileManager.default.removeItem(at: root) }

        // A pid that cannot be this test process (pid 1 is init/launchd, never a unit test).
        let table = DaemonHandoffTable(generation: 1, pid: 1, sourceVersion: "1.0.0", sessions: [])
        try DaemonHandoffStore.write(table)
        let path = try TerminalServicePaths.daemonHandoffTablePath()

        XCTAssertNil(DaemonHandoffStore.consume())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testConsumeReturnsNilAndDeletesForFormatVersionNewerThanCurrent() throws {
        let root = try useIsolatedProfile()
        defer { try? FileManager.default.removeItem(at: root) }

        let table = DaemonHandoffTable(
            formatVersion: DaemonHandoffTable.currentFormatVersion + 1, generation: 1, pid: getpid(), sourceVersion: "1.0.0", sessions: [])
        try DaemonHandoffStore.write(table)
        let path = try TerminalServicePaths.daemonHandoffTablePath()

        XCTAssertNil(DaemonHandoffStore.consume())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - golden v1 fixture (new-reads-old regression gate)

    /// Hand-written format-v1 payload that also carries a field no build of this format knows
    /// about (`futureField`, at both the table and session level). It must decode with every
    /// known field intact and the unknown fields silently ignored: this is the forever
    /// regression gate for the handoff table's "new-reads-old" promise. Do not edit this
    /// literal when the format version bumps — add a new fixture/test alongside it instead.
    private static let goldenV1FixtureWithUnknownField = #"""
        {
          "formatVersion": 1,
          "generation": 3,
          "pid": 4242,
          "sourceVersion": "0.9.0",
          "writtenAt": "2026-01-01T00:00:00.000Z",
          "sessions": [
            {
              "sessionID": "session-golden",
              "masterFD": 11,
              "childPID": 2222,
              "columns": 80,
              "rows": 24,
              "ownerEpoch": 3,
              "screenStateRevision": 5,
              "appearance": "light",
              "futureField": true
            }
          ],
          "futureField": true
        }
        """#

    func testGoldenV1FixtureWithUnknownFieldDecodesWithAllKnownFieldsIntact() throws {
        let data = Data(Self.goldenV1FixtureWithUnknownField.utf8)
        let table = try JSONDecoder().decode(DaemonHandoffTable.self, from: data)
        XCTAssertEqual(table.formatVersion, 1)
        XCTAssertEqual(table.generation, 3)
        XCTAssertEqual(table.pid, 4242)
        XCTAssertEqual(table.sourceVersion, "0.9.0")
        XCTAssertEqual(table.writtenAt, "2026-01-01T00:00:00.000Z")
        XCTAssertEqual(table.sessions.count, 1)
        let session = try XCTUnwrap(table.sessions.first)
        XCTAssertEqual(session.sessionID, "session-golden")
        XCTAssertEqual(session.masterFD, 11)
        XCTAssertEqual(session.childPID, 2222)
        XCTAssertEqual(session.columns, 80)
        XCTAssertEqual(session.rows, 24)
        XCTAssertEqual(session.ownerEpoch, 3)
        XCTAssertEqual(session.screenStateRevision, 5)
        XCTAssertEqual(session.appearance, "light")
    }

    // MARK: - descriptor helpers

    func testPrepareDescriptorForHandoffClearsCLOEXEC() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(fds.withUnsafeMutableBufferPointer { pipe($0.baseAddress!) }, 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        XCTAssertEqual(fcntl(fds[0], F_SETFD, FD_CLOEXEC), 0)
        XCTAssertEqual(fcntl(fds[0], F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)

        try DaemonHandoffStore.prepareDescriptorForHandoff(fds[0])

        XCTAssertEqual(fcntl(fds[0], F_GETFD) & FD_CLOEXEC, 0)
    }

    func testDescriptorLooksLikePTYMasterDistinguishesPTYFromPipeAndClosedFD() throws {
        let master = posix_openpt(O_RDWR)
        XCTAssertGreaterThanOrEqual(master, 0)
        defer { if master >= 0 { close(master) } }
        XCTAssertTrue(DaemonHandoffStore.descriptorLooksLikePTYMaster(master))

        var fds: [Int32] = [0, 0]
        XCTAssertEqual(fds.withUnsafeMutableBufferPointer { pipe($0.baseAddress!) }, 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        XCTAssertFalse(DaemonHandoffStore.descriptorLooksLikePTYMaster(fds[0]))

        // A descriptor number that was never opened in this process.
        XCTAssertFalse(DaemonHandoffStore.descriptorLooksLikePTYMaster(987_654))
    }

    // MARK: - instance lock adopt

    func testInstanceLockAdoptsOwnPriorRecordButRejectsForeignLivePID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lockPath = root.appendingPathComponent("daemon.lock").path

        // Leak the first lock object (never released) to simulate exec destroying the in-memory
        // TerminalServiceInstanceLock while its on-disk record survives with this process's own pid.
        let leakedLock = try TerminalServiceInstanceLock.acquire(path: lockPath)
        withExtendedLifetime(leakedLock) {
            let adopted = try? TerminalServiceInstanceLock.acquire(path: lockPath)
            XCTAssertNotNil(adopted, "Re-acquiring with this process's own pid must adopt the leaked record instead of failing.")
            adopted?.release()
        }

        // A record for a different but live process must still be rejected as a real collision.
        let foreignProcess = Process()
        foreignProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        foreignProcess.arguments = ["30"]
        try foreignProcess.run()
        defer {
            foreignProcess.terminate()
            foreignProcess.waitUntilExit()
        }
        let foreignLock = try TerminalServiceInstanceLock.acquire(path: lockPath, processID: foreignProcess.processIdentifier)
        defer { foreignLock.release() }
        XCTAssertThrowsError(try TerminalServiceInstanceLock.acquire(path: lockPath)) { error in
            guard case TerminalServiceInstanceLockError.alreadyRunning(let pid, _) = error else {
                return XCTFail("Expected an already-running lock error, got \(error).")
            }
            XCTAssertEqual(pid, foreignProcess.processIdentifier)
        }
    }

    // MARK: - preflight argv parsing

    func testRespondsToCheckParsesArgv() throws {
        let currentVersionResult = try XCTUnwrap(DaemonHandoffPreflight.respondsToCheck(arguments: ["spacesd", "--handoff-check", "1"]))
        XCTAssertEqual(currentVersionResult, 0)

        let futureVersionResult = try XCTUnwrap(
            DaemonHandoffPreflight.respondsToCheck(arguments: ["spacesd", "--handoff-check", "\(DaemonHandoffTable.currentFormatVersion + 1)"]))
        XCTAssertNotEqual(futureVersionResult, 0)

        let missingVersionResult = try XCTUnwrap(DaemonHandoffPreflight.respondsToCheck(arguments: ["spacesd", "--handoff-check"]))
        XCTAssertNotEqual(missingVersionResult, 0)

        XCTAssertNil(DaemonHandoffPreflight.respondsToCheck(arguments: ["spacesd", "--foo", "bar"]))
    }

    // MARK: - preflight child spawn

    func testPreflightRunSucceedsForZeroExitChild() throws {
        try DaemonHandoffPreflight.run(executablePath: "/usr/bin/true", formatVersion: DaemonHandoffTable.currentFormatVersion)
    }

    func testPreflightRunThrowsCheckFailedForNonzeroExitChild() throws {
        XCTAssertThrowsError(try DaemonHandoffPreflight.run(executablePath: "/usr/bin/false", formatVersion: DaemonHandoffTable.currentFormatVersion))
        { error in guard case DaemonHandoffPreflightError.checkFailed = error else { return XCTFail("expected checkFailed, got \(error)") } }
    }

    func testPreflightRunThrowsLaunchFailedForMissingExecutable() throws {
        XCTAssertThrowsError(
            try DaemonHandoffPreflight.run(
                executablePath: "/nonexistent/spacesd-\(UUID().uuidString)", formatVersion: DaemonHandoffTable.currentFormatVersion)
        ) { error in guard case DaemonHandoffPreflightError.launchFailed = error else { return XCTFail("expected launchFailed, got \(error)") } }
    }

    func testPreflightRunKillsChildAndThrowsOnDeadline() throws {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-preflight-hang-\(UUID().uuidString).sh")
        try "#!/bin/sh\nsleep 30\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let startedAt = Date()
        XCTAssertThrowsError(
            try DaemonHandoffPreflight.run(executablePath: scriptURL.path, formatVersion: DaemonHandoffTable.currentFormatVersion, deadlineSeconds: 1)
        ) { error in guard case DaemonHandoffPreflightError.timedOut = error else { return XCTFail("expected timedOut, got \(error)") } }
        // The deadline must bound the wall time; the 30s child is killed, not waited for.
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
    }
}
