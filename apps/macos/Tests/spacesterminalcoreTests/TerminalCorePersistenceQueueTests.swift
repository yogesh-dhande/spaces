import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalCorePersistenceQueueTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var databaseRoot: URL?

    /// Points the profile database at a per-suite temp root so the break/restore-database tests never touch
    /// the user's real profile database (which may also be schema-newer or daemon-owned, refusing to open).
    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
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
        queue.enqueueWrite { barrier.wait() }
        for value in 1...5 { queue.enqueueCoalescedWrite(key: "k") { recorder.record(value) } }
        barrier.signal()
        queue.drain()
        XCTAssertEqual(recorder.recorded, [5])
    }

    /// Coalescing is per key: two different keys each keep their own newest write.
    func testCoalescedWritesAreKeyedIndependently() {
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.coalesce-keyed")
        let recorder = OrderRecorder()
        let barrier = DispatchSemaphore(value: 0)
        queue.enqueueWrite { barrier.wait() }
        queue.enqueueCoalescedWrite(key: "a") { recorder.record(1) }
        queue.enqueueCoalescedWrite(key: "b") { recorder.record(10) }
        queue.enqueueCoalescedWrite(key: "a") { recorder.record(2) }
        queue.enqueueCoalescedWrite(key: "b") { recorder.record(20) }
        barrier.signal()
        queue.drain()
        // Only the newest of each key runs, and FIFO preserves the enqueue order of those survivors.
        XCTAssertEqual(recorder.recorded, [2, 20])
    }

    /// Uncoalesced writes run in strict FIFO enqueue order, and `drain()` blocks until they have all run.
    func testUncoalescedWritesRunFIFOAndDrainBlocks() {
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.fifo")
        let recorder = OrderRecorder()
        for value in 1...50 { queue.enqueueWrite { recorder.record(value) } }
        queue.drain()
        XCTAssertEqual(recorder.recorded, Array(1...50))
    }

    /// `drainAsync()` suspends until every enqueued write has run.
    func testDrainAsyncAwaitsQueuedWrites() async {
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.drain-async")
        let recorder = OrderRecorder()
        for value in 1...20 { queue.enqueueWrite { recorder.record(value) } }
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

    private func makeRunningState(sessionID: String, title: String) -> TerminalSessionRuntimeState {
        TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: getpid(), childPID: nil, state: .running,
            updatedAt: TerminalSessionTimestamp.string(from: Date()), title: title, workingDirectory: "/tmp/original")
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
        try Self.breakDatabase(at: databasePath)

        let queue = TerminalCorePersistenceQueue(label: "test.persistence.running-retry")
        let recorder = PersistedTitleRecorder()
        let updatedState = makeRunningState(sessionID: launchConfiguration.sessionID, title: "after")
        queue.enqueueRuntimeStateWrite(updatedState, at: Date(), paths: paths) { state, _ in recorder.record(state.title ?? "") }
        // The first attempt fails against the broken database and the write is now retrying in place. Wait past
        // the first retry delay to guarantee a genuine failure occurred, then restore so a later attempt lands.
        try await Task.sleep(nanoseconds: 250_000_000)
        try Self.restoreDatabase(at: databasePath)

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
        try Self.breakDatabase(at: databasePath)

        let queue = TerminalCorePersistenceQueue(label: "test.persistence.supersede-retry")
        let recorder = PersistedTitleRecorder()
        queue.enqueueRuntimeStateWrite(makeRunningState(sessionID: launchConfiguration.sessionID, title: "old"), at: Date(), paths: paths) {
            state, _ in recorder.record(state.title ?? "")
        }
        // Let the older write fail and enter its retry loop, then supersede it with a newer write for the same
        // coalescing key. The generation bump happens synchronously at enqueue, so the older write abandons on
        // its next retry check rather than looping to exhaustion.
        try await Task.sleep(nanoseconds: 100_000_000)
        queue.enqueueRuntimeStateWrite(makeRunningState(sessionID: launchConfiguration.sessionID, title: "new"), at: Date(), paths: paths) {
            state, _ in recorder.record(state.title ?? "")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        try Self.restoreDatabase(at: databasePath)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, recorder.recorded.isEmpty { try? await Task.sleep(nanoseconds: 25_000_000) }
        await queue.drainAsync()
        XCTAssertEqual(recorder.recorded, ["new"], "only the superseding newer write may commit; the failing older write must abandon its retry")
        XCTAssertEqual(try TerminalSessionPersistence.readRuntimeState(paths: paths).title, "new")
    }

    /// Replaces the SQLite database (and its WAL sidecars) with a directory so every write fails to open it,
    /// preserving the real files aside so `restoreDatabase` can bring the committed data back intact.
    private static func breakDatabase(at databasePath: String) throws {
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
