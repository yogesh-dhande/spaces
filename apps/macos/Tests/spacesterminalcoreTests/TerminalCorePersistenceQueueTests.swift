import Foundation
import XCTest

@testable import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class TerminalCorePersistenceQueueTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var databaseRoot: URL?

    /// The retry tests deliberately break the profile database, and parallel test workers share the
    /// worktree profile, so every test in this suite runs against its own throwaway profile root — a
    /// broken database here must never be observable from a concurrently running suite (or vice versa).
    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        // Without this, SpacesProfile.current() below can return a profile a sibling test cached before
        // this suite pointed SPACES_DB_PATH at its own throwaway root, and breakDatabase would then
        // destroy that stale (possibly real, shared) database instead of this suite's own.
        SpacesProfile.resetCacheForTesting()
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        SpacesProfile.resetCacheForTesting()
        if let databaseRoot { try? FileManager.default.removeItem(at: databaseRoot) }
        databaseRoot = nil
        originalDatabasePath = nil
        originalRuntimeDirectory = nil
        try super.tearDownWithError()
    }
    /// Records the order in which queued writes actually run, guarded so the serial queue and the draining
    /// test thread never race on the array.
    private final class OrderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []

        func record(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var recorded: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// A burst of coalesced writes for one key collapses to a single run of the newest value: earlier
    /// generations are superseded before they run because the queue is parked until every write is enqueued.
    func testCoalescedWriteRunsOnlyLatestForKey() {
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.coalesce")
        let recorder = OrderRecorder()
        // Park the serial queue so all five enqueues land before any runs; the gate then supersedes the
        // first four when the barrier releases.
        let barrier = DispatchSemaphore(value: 0)
        queue.enqueueOrderedWork { barrier.wait() }
        for value in 1...5 { queue.enqueueCoalescedWrite(key: "k") { _ in recorder.record(value) } }
        barrier.signal()
        queue.drain()
        XCTAssertEqual(recorder.recorded, [5])
    }

    /// Coalescing is per key: two different keys each keep their own newest write.
    func testCoalescedWritesAreKeyedIndependently() {
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.coalesce-keyed")
        let recorder = OrderRecorder()
        let barrier = DispatchSemaphore(value: 0)
        queue.enqueueOrderedWork { barrier.wait() }
        queue.enqueueCoalescedWrite(key: "a") { _ in recorder.record(1) }
        queue.enqueueCoalescedWrite(key: "b") { _ in recorder.record(10) }
        queue.enqueueCoalescedWrite(key: "a") { _ in recorder.record(2) }
        queue.enqueueCoalescedWrite(key: "b") { _ in recorder.record(20) }
        barrier.signal()
        queue.drain()
        // Only the newest of each key runs, and FIFO preserves the enqueue order of those survivors.
        XCTAssertEqual(recorder.recorded, [2, 20])
    }

    /// Uncoalesced writes run in strict FIFO enqueue order, and `drain()` blocks until they have all run.
    func testUncoalescedWritesRunFIFOAndDrainBlocks() {
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.fifo")
        let recorder = OrderRecorder()
        for value in 1...50 { queue.enqueueOrderedWork { recorder.record(value) } }
        queue.drain()
        XCTAssertEqual(recorder.recorded, Array(1...50))
    }

    /// `drainAsync()` suspends until every enqueued write has run.
    func testDrainAsyncAwaitsQueuedWrites() async {
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.drain-async")
        let recorder = OrderRecorder()
        for value in 1...20 { queue.enqueueOrderedWork { recorder.record(value) } }
        await queue.drainAsync()
        XCTAssertEqual(recorder.recorded, Array(1...20))
    }

    // MARK: - Runtime-state write retry (Bug R4-7)

    /// Thread-safe collector for the titles of runtime-state writes that reached `onPersisted` — i.e. that
    /// actually committed. A dropped write never records; the newest-wins survivor records exactly once.
    private final class PersistedTitleRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var titles: [String] = []

        func record(_ title: String) {
            lock.lock()
            titles.append(title)
            lock.unlock()
        }

        var recorded: [String] {
            lock.lock()
            defer { lock.unlock() }
            return titles
        }
    }

    /// Deterministic stand-in for the persistence queue's retry back-off, injected as its `sleep` closure.
    /// Unlike the production `Thread.sleep`, this blocks the retry loop on a semaphore the test controls
    /// directly: `waitForRetry()` proves a retry attempt genuinely failed and is now paused (without waiting
    /// on real wall-clock time to "outlast" the delay), and `releaseOneRetry()` lets exactly that one paused
    /// attempt proceed. This keeps a retry loop paused for as long as the test needs — e.g. long enough to
    /// enqueue a superseding write — instead of racing a non-blocking stub through all of its attempts before
    /// the test thread gets a chance to interject.
    private final class RetryGate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)

        func sleep(_: TimeInterval) {
            entered.signal()
            release.wait()
        }

        @discardableResult func waitForRetry(timeout: DispatchTime = .now() + 5) -> Bool { entered.wait(timeout: timeout) == .success }
        func releaseOneRetry() { release.signal() }
    }

    /// A throwaway profile root, cleaned up with the rest of the test's temporary state.
    private func makeProfileRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeRunningState(sessionID: String, title: String) -> TerminalSessionRuntimeState {
        TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .running,
            updatedAt: TerminalSessionTimestamp.string(from: Date()), title: title, workingDirectory: "/tmp/original")
    }

    /// A queued write commits to the database that was current when it was ENQUEUED, never to whatever
    /// profile is current when the serial queue finally reaches it.
    ///
    /// A core's `terminate()` returns with its final writes still queued, so a test whose teardown restores
    /// the profile environment would otherwise have those writes land in the restored profile — the exact
    /// mechanism by which fixture sessions escaped tests that did isolate themselves. The barrier makes the
    /// ordering explicit rather than timed: the write cannot run until the profile has already moved.
    func testQueuedRuntimeStateWriteCommitsToTheProfileBoundWhenItWasEnqueued() throws {
        let enqueueTimeDatabasePath = try makeProfileRoot().appendingPathComponent("spaces.db").path
        let executionTimeDatabasePath = try makeProfileRoot().appendingPathComponent("spaces.db").path
        let sessionRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionRoot) }
        let paths = TerminalSessionPaths(rootDirectory: sessionRoot.path)
        try paths.ensureDirectories()
        let state = makeRunningState(sessionID: "session-enqueue-time-profile", title: "queued")

        setenv("SPACES_DB_PATH", enqueueTimeDatabasePath, 1)
        // The session belongs to the enqueue-time profile, so its `terminal_sessions` row is written there —
        // the way a core writes its launch configuration into the current profile before enqueuing any
        // runtime-state write against it. Only this profile gets the row, which is what keeps the
        // execution-time assertion below an honest "no row here at all".
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: state.sessionID, title: "queued", workingDirectory: "/tmp/original", shell: "/bin/zsh", command: nil,
                createdAt: TerminalSessionTimestamp.string(from: Date()), workspaceID: "workspace-1", kind: .shell), paths: paths)
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.enqueue-time-profile")
        // Park the serial queue so the runtime-state write is still pending when the profile moves.
        let barrier = DispatchSemaphore(value: 0)
        queue.enqueueOrderedWork { barrier.wait() }
        queue.enqueueRuntimeStateWrite(state, at: Date(), paths: paths, onPersisted: { _, _ in })

        // Stands in for a test teardown restoring the environment while the write is still queued.
        setenv("SPACES_DB_PATH", executionTimeDatabasePath, 1)
        barrier.signal()
        queue.drain()

        setenv("SPACES_DB_PATH", enqueueTimeDatabasePath, 1)
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).title, "queued")
        setenv("SPACES_DB_PATH", executionTimeDatabasePath, 1)
        XCTAssertThrowsError(try TerminalSessionPersistence.readRuntimeState(paths: paths)) { error in
            guard case TerminalSessionPersistenceError.unknownSession = error else {
                return XCTFail("Expected no row in the profile that was current at execution time, got \(error).")
            }
        }
    }

    /// A write enqueued while the profile could NOT be resolved is abandoned, never re-attributed to
    /// whatever profile is current when the queue reaches it.
    ///
    /// Resolution failing is reachable, not theoretical: profile resolution refuses a live user profile in
    /// a test process, so binding `SPACES_DB_PATH` inside one makes the enqueue-time resolution throw. If
    /// that failure collapsed into "no explicit database", the write would resolve the profile bound
    /// afterwards and commit there — the reassignment the enqueue-time capture exists to prevent.
    func testQueuedWriteWhoseProfileFailedToResolveIsNotReboundToALaterProfile() throws {
        let accountHomeURL = URL(fileURLWithPath: try XCTUnwrap(SpacesProfile.accountHomeDirectoryPath()), isDirectory: true)
        let refusedRoot = accountHomeURL.appendingPathComponent(".spaces-dev/profiles/spaces/queue-\(UUID().uuidString)", isDirectory: true)
        // The refusal means this is never created; the teardown matters when the guard is deliberately
        // stubbed out to prove this test fails without it, which otherwise leaves fixtures in the
        // developer's real profile — the very thing under test.
        addTeardownBlock { try? FileManager.default.removeItem(at: refusedRoot) }
        let laterDatabasePath = try makeProfileRoot().appendingPathComponent("spaces.db").path
        let sessionRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionRoot) }
        let paths = TerminalSessionPaths(rootDirectory: sessionRoot.path)
        try paths.ensureDirectories()
        let state = makeRunningState(sessionID: "session-unresolved-profile", title: "abandoned")

        let queue = TerminalCorePersistenceQueue(label: "test.persistence.unresolved-profile")
        // Park the queue while the profile still resolves, so parking is not itself the failing step.
        let barrier = DispatchSemaphore(value: 0)
        queue.enqueueOrderedWork { barrier.wait() }

        // Enqueue under a profile that resolution refuses.
        setenv("SPACES_DB_PATH", refusedRoot.appendingPathComponent("spaces.db", isDirectory: false).path, 1)
        queue.enqueueRuntimeStateWrite(state, at: Date(), paths: paths, onPersisted: { _, _ in })

        // Bind a perfectly good profile afterwards — the one the abandoned write must never reach.
        setenv("SPACES_DB_PATH", laterDatabasePath, 1)
        barrier.signal()
        queue.drain()

        XCTAssertThrowsError(try TerminalSessionPersistence.readRuntimeState(paths: paths)) { error in
            guard case TerminalSessionPersistenceError.unknownSession = error else {
                return XCTFail("Expected the abandoned write to have committed nowhere, got \(error).")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: refusedRoot.path), "A refused resolution must not have created the live profile directory.")
    }

    /// A failed NON-exited (running) runtime-state write must retry in place and eventually commit once the
    /// database recovers. Before the R4-7 fix the retry loop bailed on the first failure of any non-`.exited`
    /// state (`guard state.state == .exited`), so a running-state write was silently dropped and `onPersisted`
    /// never fired — the durable row kept its stale prior value. The Linux headless core has no periodic
    /// runtime-state refresh, so nothing re-persists it on its own. Breaking the database makes the first
    /// attempt fail; restoring it lets the bounded retry land the write.
    func testFailedRunningRuntimeStateWriteRetriesUntilItCommits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-r4-7-running-retry", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)
        // Seed a durable running row with the OLD title so a dropped write is observable as staleness.
        try TerminalSessionPersistence.writeRuntimeState(makeRunningState(sessionID: launchConfiguration.sessionID, title: "before"), paths: paths)
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).title, "before")

        let databasePath = try SpacesProfile.current().databasePath
        try Self.breakDatabase(at: databasePath, allowedRoot: XCTUnwrap(databaseRoot))

        // Virtualize the retry back-off with a `RetryGate` instead of a real sleep sized to outlast the
        // production delay: it proves the first attempt genuinely failed and is now paused before we restore
        // the database.
        let retryGate = RetryGate()
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.running-retry", runtimeStateWriteRetryDelay: 0.001, sleep: retryGate.sleep)
        let recorder = PersistedTitleRecorder()
        let updatedState = makeRunningState(sessionID: launchConfiguration.sessionID, title: "after")
        queue.enqueueRuntimeStateWrite(updatedState, at: Date(), paths: paths) { state, _ in recorder.record(state.title ?? "") }
        XCTAssertTrue(retryGate.waitForRetry(), "the first write attempt must genuinely fail against the broken database")
        try Self.restoreDatabase(at: databasePath)
        retryGate.releaseOneRetry()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, recorder.recorded.isEmpty { try? await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(recorder.recorded, ["after"], "a failed running-state write must retry and eventually commit")
        XCTAssertEqual(
            try TerminalSessionPersistence.readRuntimeState(paths: paths).title, "after",
            "the retried running-state write must land the new durable value")
    }

    /// Latest-wins supersession survives the retry: a failing OLDER running-state write abandons its retries as
    /// soon as a NEWER write for the same coalescing key is enqueued (bumping the generation), so it can never
    /// overwrite the newer value. The older write's first attempt fails against the broken database and begins
    /// retrying; enqueuing the newer write supersedes it; on its next retry check the older write sees a stale
    /// generation and returns without writing. Only the newer write commits once the database recovers.
    func testSupersedingRuntimeStateWriteAbandonsFailingOlderRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: "session-r4-7-supersede", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp/original", shell: "/bin/zsh",
            command: "zsh", createdAt: "2026-05-17T00:00:00Z", workspaceID: "workspace-1", kind: .shell)
        try TerminalSessionPersistence.writeLaunchConfiguration(launchConfiguration, paths: paths)

        let databasePath = try SpacesProfile.current().databasePath
        try Self.breakDatabase(at: databasePath, allowedRoot: XCTUnwrap(databaseRoot))

        // Virtualize the retry back-off with a `RetryGate`: it pauses each write's retry loop right after a
        // genuine failure, so the test can interject deterministically instead of racing real sleeps sized to
        // outlast the production delay.
        let retryGate = RetryGate()
        let queue = TerminalCorePersistenceQueue(
            label: "test.persistence.supersede-retry", runtimeStateWriteRetryDelay: 0.001, sleep: retryGate.sleep)
        let recorder = PersistedTitleRecorder()
        queue.enqueueRuntimeStateWrite(makeRunningState(sessionID: launchConfiguration.sessionID, title: "old"), at: Date(), paths: paths) {
            state, _ in recorder.record(state.title ?? "")
        }
        // Let the older write fail and pause in its retry loop, then supersede it with a newer write for the
        // same coalescing key. The generation bump happens synchronously at enqueue, so releasing the older
        // write's paused retry lets it see a stale generation on its next check and abandon (no further sleep
        // call) rather than looping to exhaustion.
        XCTAssertTrue(retryGate.waitForRetry(), "the older write must genuinely fail before being superseded")
        queue.enqueueRuntimeStateWrite(makeRunningState(sessionID: launchConfiguration.sessionID, title: "new"), at: Date(), paths: paths) {
            state, _ in recorder.record(state.title ?? "")
        }
        retryGate.releaseOneRetry()
        // The newer write now runs (FIFO behind the older's abandoned closure) and its own first attempt fails
        // against the still-broken database, pausing in turn. Wait for that genuine failure before restoring.
        XCTAssertTrue(retryGate.waitForRetry(), "the newer write must genuinely fail before the database is restored")
        try Self.restoreDatabase(at: databasePath)
        retryGate.releaseOneRetry()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, recorder.recorded.isEmpty { try? await Task.sleep(nanoseconds: 25_000_000) }
        await queue.drainAsync()
        XCTAssertEqual(recorder.recorded, ["new"], "only the superseding newer write may commit; the failing older write must abandon its retry")
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).title, "new")
    }

    /// Replaces the SQLite database (and its WAL sidecars) with a directory so every write fails to open it,
    /// preserving the real files aside so `restoreDatabase` can bring the committed data back intact.
    ///
    /// `databasePath` comes from `SpacesProfile.current()`, which is process-wide cached state; a stale
    /// entry left by a sibling test (or a future test in this suite that forgets to reset the cache)
    /// could point this at a real, shared database. Refuse to touch anything outside this suite's own
    /// throwaway profile root instead of silently destroying it.
    private static func breakDatabase(at databasePath: String, allowedRoot: URL) throws {
        struct UnsafeDatabasePath: Error { let path: String }
        guard databasePath.hasPrefix(allowedRoot.path + "/") else {
            // Throw (don't just XCTFail-and-return): the callers' later restoreDatabase(at:)
            // starts by deleting databasePath, so continuing would destroy the very database
            // this guard refused to touch.
            XCTFail("refusing to break database at \(databasePath): outside this test's isolated root \(allowedRoot.path)")
            throw UnsafeDatabasePath(path: databasePath)
        }
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = databasePath + suffix
            if fileManager.fileExists(atPath: path) { try fileManager.moveItem(atPath: path, toPath: path + ".r47bak") }
        }
        try fileManager.createDirectory(atPath: databasePath, withIntermediateDirectories: false)
    }

    private static func restoreDatabase(at databasePath: String) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: databasePath)
        for suffix in ["", "-wal", "-shm"] {
            let backup = databasePath + suffix + ".r47bak"
            if fileManager.fileExists(atPath: backup) { try fileManager.moveItem(atPath: backup, toPath: databasePath + suffix) }
        }
    }
}
