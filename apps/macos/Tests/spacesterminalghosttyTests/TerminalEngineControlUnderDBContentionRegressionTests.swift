import Dispatch
import Foundation
import SQLite3
import XCTest

@testable import spacesterminalcore
@testable import spacesterminalghostty

/// Regression for the interactive freeze under database write contention (the daemon persistence offload).
///
/// The user-reproduced defect: a Claude session's `SessionStart` hook fires `spaces agent signal` right as
/// typing begins, bursting durable writes at the shared SQLite database. While the engine still performed
/// its own writes (client lease touches per control request, the runtime-state timer's persist) inline on
/// the terminal engine executor, those writes blocked on the WAL write lock up to the 5s busy timeout, so
/// every control request — and thus all terminal I/O — froze for bounded seconds, then recovered.
///
/// This drives control sends through the engine's synchronous bridge WHILE a competing writer holds the
/// shared write lock and asserts each round-trip stays fast and the PTY echo keeps flowing. With the durable
/// writes moved off the engine onto the per-core persistence queue, a held write lock can no longer touch
/// engine latency; before the fix the inline lease write on the send path blocked on the lock and the
/// round-trip exceeded the budget by seconds.
///
/// A plain (non-`@MainActor`, non-engine) `XCTestCase` with an `async` method so it runs on a
/// cooperative-pool thread — the only context from which the engine's `runSynchronously` bridge is legal.
final class TerminalEngineControlUnderDBContentionRegressionTests: XCTestCase {

    override func setUpWithError() throws { try useIsolatedSpacesProfile() }

    /// Carries the engine-isolated core to the engine bridge from a background thread; the core is only ever
    /// *used* on the engine actor.
    private final class CoreBox: @unchecked Sendable {
        let core: GhosttyEmbeddedSessionCore
        let paths: TerminalSessionPaths
        let outputPath: String
        let root: URL
        init(core: GhosttyEmbeddedSessionCore, paths: TerminalSessionPaths, root: URL) {
            self.core = core
            self.paths = paths
            self.outputPath = paths.outputPath
            self.root = root
        }
    }

    /// Holds the shared database's write lock (`BEGIN IMMEDIATE`) from a background thread until released,
    /// standing in for the agent hook's `spaces agent signal` write burst. Raw SQLite3 so it contends the
    /// exact WAL write lock the terminal engine's durable writes take. `ROLLBACK` (not `COMMIT`) leaves the
    /// shared database untouched.
    private final class CompetingWriteLockHolder: @unchecked Sendable {
        private let databasePath: String
        private let acquired = DispatchSemaphore(value: 0)
        private let releaseNow = DispatchSemaphore(value: 0)

        init(databasePath: String) { self.databasePath = databasePath }

        func startHolding(maxHoldSeconds: TimeInterval) {
            Thread.detachNewThread { [databasePath, acquired, releaseNow] in
                var handle: OpaquePointer?
                guard sqlite3_open(databasePath, &handle) == SQLITE_OK, let handle else {
                    acquired.signal()
                    return
                }
                defer { sqlite3_close(handle) }
                sqlite3_busy_timeout(handle, 5000)
                // BEGIN IMMEDIATE reserves the write lock at once, so every other connection's write blocks
                // until this transaction ends — exactly the contention the agent-signal burst produces.
                guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                    acquired.signal()
                    return
                }
                acquired.signal()
                _ = releaseNow.wait(timeout: .now() + maxHoldSeconds)
                _ = sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            }
        }

        func waitUntilHolding() { acquired.wait() }
        func release() { releaseNow.signal() }
    }

    func testControlSendsStayFastWhileCompetingWriterHoldsTheDatabaseWriteLock() async throws {
        // A PTY-backed `cat` session that echoes stdin, so a control send's bytes come back in the transcript.
        let box = try await TerminalEngineActor.run { () -> CoreBox in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launch = TerminalSessionLaunchConfiguration(
                sessionID: "engine-dbcontention-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-07-21T00:00:00Z",
                workspaceID: "workspace-1", kind: .shell)
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: launch, paths: paths)
            try core.startIfNeeded()
            // Attach a local-window owner so owner-gated sends are accepted and their lease touch fires the
            // durable write path this regression guards.
            let owner = TerminalClient(
                id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-07-21T00:00:00Z")
            try core.attachClient(owner, mode: .owner)
            return CoreBox(core: core, paths: paths, root: root)
        }
        defer { try? FileManager.default.removeItem(at: box.root) }

        // Attach a state-stream subscriber so the per-request broadcast pipeline actually runs (the product
        // scenario, a GUI mirror), matching the reproduction where broadcasts and control interleave.
        let subscriber = GhosttyRemoteSessionStateStreamClient(socketPath: box.paths.subscriptionSocketPath, onEvent: { _ in }, onDisconnect: {})
        try subscriber.start()
        defer { subscriber.stop() }

        // Flush any startup/attach persistence backlog so the queue is empty before we contend the lock.
        TerminalEngineActor.runSynchronously { box.core.debugDrainPersistenceQueue() }

        let lockHolder = CompetingWriteLockHolder(databasePath: try SpacesProfile.current().databasePath)
        lockHolder.startHolding(maxHoldSeconds: 10)
        lockHolder.waitUntilHolding()
        // Release the lock BEFORE terminate: terminate drains the persistence queue, whose writes are blocked
        // on this held lock. Defers run LIFO, so this (registered after the removeItem defer) runs first.
        var released = false
        let releaseLock = {
            if !released {
                released = true
                lockHolder.release()
            }
        }
        defer { releaseLock() }

        // Drive several owner sends through the engine bridge WHILE the write lock is held. Each must return
        // well under budget: post-fix the send only enqueues its lease write off the engine; pre-fix it wrote
        // the lease inline and blocked on the held lock up to the 5s busy timeout.
        var worstRoundTrip: TimeInterval = 0
        var lastMarker = ""
        for index in 0..<5 {
            let marker = "dbcontention-\(index)-\(UUID().uuidString.prefix(6))"
            lastMarker = marker
            let startedAt = Date()
            let ok = TerminalEngineActor.runSynchronously { () -> Bool in
                box.core.handleControlRequest(.init(command: "send", text: "\(marker)\n", clientID: "owner-client", appendNewline: false)).ok
            }
            let roundTrip = Date().timeIntervalSince(startedAt)
            worstRoundTrip = max(worstRoundTrip, roundTrip)
            XCTAssertTrue(ok, "owner send \(index) should be accepted while the write lock is held")
            XCTAssertLessThan(
                roundTrip, 0.5, "control send \(index) took \(roundTrip)s while the DB write lock was held — the engine blocked on a durable write")
        }
        XCTAssertLessThan(worstRoundTrip, 0.5, "worst control-send round-trip \(worstRoundTrip)s exceeded the budget under DB contention")

        // PTY echo must still flow while the lock is held: the send's bytes reach `cat` (off the blocked DB
        // path) and echo back into the transcript. This proves terminal I/O is not gated on the DB lock.
        let echoDeadline = Date().addingTimeInterval(5.0)
        var sawEcho = false
        while Date() < echoDeadline {
            if let data = FileManager.default.contents(atPath: box.outputPath), let transcript = String(data: data, encoding: .utf8),
                transcript.contains(lastMarker)
            {
                sawEcho = true
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(sawEcho, "PTY echo did not reach the transcript while the DB write lock was held — terminal I/O was gated on the DB")

        releaseLock()
        TerminalEngineActor.runSynchronously { box.core.terminate() }
    }

    /// Finding B3 companion: terminating one core must not stall another live core's control requests. Both
    /// cores share the single terminal-engine executor. Before the fix, `terminate()` ended with a blocking
    /// `persistenceQueue.sync {}` drain; under a held write lock that drain blocked the engine thread up to
    /// SQLite's 5s busy timeout, freezing every other session. With the fence made non-blocking, terminating
    /// one core under a held write lock leaves another core's control round-trip fast.
    func testTerminatingOneCoreUnderHeldWriteLockDoesNotStallAnotherCoresControl() async throws {
        @TerminalEngineActor func makeCoreBox(tag: String) throws -> CoreBox {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let paths = TerminalSessionPaths(rootDirectory: root.path)
            try paths.ensureDirectories()
            let launch = TerminalSessionLaunchConfiguration(
                sessionID: "engine-b3-\(tag)-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "cat", createdAt: "2026-07-21T00:00:00Z",
                workspaceID: "workspace-1", kind: .shell)
            let core = GhosttyEmbeddedSessionCore(launchConfiguration: launch, paths: paths)
            try core.startIfNeeded()
            let owner = TerminalClient(
                id: "owner-client", kind: .localWindow, identity: .init(label: "Spaces window"), connectedAt: "2026-07-21T00:00:00Z")
            try core.attachClient(owner, mode: .owner)
            return CoreBox(core: core, paths: paths, root: root)
        }

        let terminatingBox = try await TerminalEngineActor.run { try makeCoreBox(tag: "terminating") }
        let liveBox = try await TerminalEngineActor.run { try makeCoreBox(tag: "live") }
        defer {
            try? FileManager.default.removeItem(at: terminatingBox.root)
            try? FileManager.default.removeItem(at: liveBox.root)
        }

        // Flush startup/attach backlog so the queues are empty before we contend the lock.
        TerminalEngineActor.runSynchronously {
            terminatingBox.core.debugDrainPersistenceQueue()
            liveBox.core.debugDrainPersistenceQueue()
        }

        let lockHolder = CompetingWriteLockHolder(databasePath: try SpacesProfile.current().databasePath)
        lockHolder.startHolding(maxHoldSeconds: 10)
        lockHolder.waitUntilHolding()
        var released = false
        let releaseLock = {
            if !released {
                released = true
                lockHolder.release()
            }
        }
        defer { releaseLock() }

        // Terminate one core on a background thread so it is in flight on the shared engine while the lock is
        // held. Before the fix its blocking drain holds the engine thread; with the fix it returns at once.
        let terminated = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            TerminalEngineActor.runSynchronously { terminatingBox.core.terminate() }
            terminated.signal()
        }
        // Let the terminate reach the engine before measuring the other core.
        try await Task.sleep(nanoseconds: 100_000_000)

        // Drive a control send to the OTHER core through the shared engine bridge and time the round-trip.
        let startedAt = Date()
        let ok = TerminalEngineActor.runSynchronously { () -> Bool in
            liveBox.core.handleControlRequest(.init(command: "send", text: "b3-marker\n", clientID: "owner-client", appendNewline: false)).ok
        }
        let roundTrip = Date().timeIntervalSince(startedAt)
        XCTAssertTrue(ok, "the live core's owner send should be accepted while the other core terminates under the held lock")
        XCTAssertLessThan(
            roundTrip, 0.5,
            "terminating one core under a held write lock stalled another core's control for \(roundTrip)s — the termination fence blocked the engine"
        )
        XCTAssertEqual(
            terminated.wait(timeout: .now() + 1), .success,
            "terminate() did not return promptly — its durable fence blocked the engine on the write lock")

        releaseLock()
        TerminalEngineActor.runSynchronously { liveBox.core.terminate() }
    }
}
