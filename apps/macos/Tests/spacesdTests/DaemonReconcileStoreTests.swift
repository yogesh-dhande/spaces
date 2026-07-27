import Foundation
import XCTest
import spacesterminalcore
import workspacecore

@testable import spacesd

/// The daemon's hot reconcile loops keep one database connection alive across passes instead of
/// opening and closing one per notification. These cover what that reuse must not break: every pass
/// still sees the database's current contents (including writes another process made between
/// passes), a failing pass does not poison the ones after it, and closing is final — the connection
/// released when the owning service stops is the last one, whatever arrives afterwards.
final class DaemonReconcileStoreTests: XCTestCase {
    private var directory: URL!
    private var databasePath: String!
    private var originalDatabasePath: String?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("daemon-reconcile-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databasePath = directory.appendingPathComponent("spaces.db").path
        // Opening a store authorizes schema migration against the active profile, so the test database
        // has to be the active profile too — otherwise the test resolves the developer's.
        originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
        setenv(SpacesProfile.databasePathEnvironmentVariable, databasePath, 1)
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath {
            setenv(SpacesProfile.databasePathEnvironmentVariable, originalDatabasePath, 1)
        } else {
            unsetenv(SpacesProfile.databasePathEnvironmentVariable)
        }
        if let directory, FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        directory = nil
        databasePath = nil
    }

    /// A reconcile pass computes the router's route table. Reusing one connection must not serve a
    /// stale snapshot: a port assignment written by a different connection between passes has to
    /// show up in the next pass's routes, and one removed has to disappear.
    func testRepeatedPassesSeeWritesMadeByAnotherConnectionBetweenPasses() async throws {
        let seedStore = try SQLiteStore(path: databasePath)
        let project = ProjectRecord(
            id: "project-router", name: "Router", dir: "/projects/router", isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil,
            ports: [], processes: [], browserSessions: [])
        try seedStore.upsert(project: project)
        let workspace = WorkspaceRecord(
            id: "workspace-router", projectID: project.id, dir: "/projects/router", dirname: nil, branch: nil, isDefault: false, isArchived: false,
            isRunning: false, lastLaunchedAt: nil)
        try seedStore.upsert(workspace: workspace)
        try seedStore.setWorkspacePorts(workspaceID: workspace.id, ports: [21001], names: ["web"])

        let observedRoutes = LockedRoutesBox()
        let reconcileStore = DaemonReconcileStore(label: "test.reconcile.routes", databasePath: databasePath) { store in
            observedRoutes.set(try WorkspaceOrchestrator(store: store).caddyRouteTable())
        }
        defer { reconcileStore.close() }

        try await reconcileStore.runPass()
        let slug = SpacesProfile.workspaceHostSlug(
            branch: workspace.branch, projectName: project.name, isGitRepo: project.isGitRepo, workspaceID: workspace.id)
        XCTAssertEqual(observedRoutes.hosts(), ["web.\(slug).localhost"])

        // A different connection stands in for the app, the CLI, or another daemon service writing
        // between two passes — the case a reused connection could serve stale.
        try seedStore.setWorkspacePorts(workspaceID: workspace.id, ports: [21001, 21002], names: ["web", "backend"])
        try await reconcileStore.runPass()
        XCTAssertEqual(observedRoutes.hosts(), ["backend.\(slug).localhost", "web.\(slug).localhost"])
        XCTAssertEqual(observedRoutes.upstream(forHost: "backend.\(slug).localhost"), "localhost:21002")

        try seedStore.setWorkspacePorts(workspaceID: workspace.id, ports: [], names: [])
        try await reconcileStore.runPass()
        XCTAssertEqual(observedRoutes.hosts(), [])
    }

    /// A pass that throws surfaces its error to the caller and leaves the connection usable, so a
    /// single bad pass cannot wedge the loop for the daemon's remaining lifetime.
    func testFailingPassSurfacesErrorAndLeavesLaterPassesWorking() async throws {
        let shouldFail = LockedFlagBox()
        let passCount = LockedCounterBox()
        let reconcileStore = DaemonReconcileStore(label: "test.reconcile.failure", databasePath: databasePath) { store in
            passCount.increment()
            _ = try store.projects()
            if shouldFail.value { throw NSError(domain: "test.reconcile", code: 7) }
        }
        defer { reconcileStore.close() }

        try await reconcileStore.runPass()

        shouldFail.set(true)
        do {
            try await reconcileStore.runPass()
            XCTFail("Expected the failing pass to rethrow.")
        } catch { XCTAssertEqual((error as NSError).code, 7) }

        shouldFail.set(false)
        try await reconcileStore.runPass()
        XCTAssertEqual(passCount.value, 3)
    }

    /// A service stops while a trailing re-run is still on its way, so a pass can be submitted after
    /// `close()`. That pass must do no database work and must not resurrect the connection: the
    /// checkpoint taken at close has to be the database's last word from this loop, otherwise a
    /// stopped service leaves a connection open across the daemon's exec handoff.
    func testPassSubmittedAfterCloseDoesNoWorkAndOpensNoConnection() async throws {
        let passCount = LockedCounterBox()
        let reconcileStore = DaemonReconcileStore(label: "test.reconcile.close", databasePath: databasePath) { store in
            passCount.increment()
            _ = try store.projects()
        }

        try await reconcileStore.runPass()
        XCTAssertEqual(passCount.value, 1)
        XCTAssertFalse(databaseIsCheckpointed(), "A pass should have opened the connection.")

        reconcileStore.close()
        try await reconcileStore.runPass()

        XCTAssertEqual(passCount.value, 1, "A pass after close must not run.")
        XCTAssertTrue(databaseIsCheckpointed(), "A pass after close must not reopen the connection.")
    }

    /// Closing without ever running a pass, and closing more than once, are both ordinary shutdown
    /// paths (a service can stop before its first notification, and stop can be reached twice).
    /// Neither may open a connection or trap.
    func testRepeatedCloseIsSafeAndNeverOpensAConnection() async throws {
        let passCount = LockedCounterBox()
        let reconcileStore = DaemonReconcileStore(label: "test.reconcile.repeat-close", databasePath: databasePath) { store in
            passCount.increment()
            _ = try store.projects()
        }

        reconcileStore.close()
        reconcileStore.close()
        try await reconcileStore.runPass()

        XCTAssertEqual(passCount.value, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath), "Close must not create the database.")
    }

    /// `close()` submitted while a pass is running is the harder of the two queue orders: the close lands
    /// behind work that still holds the connection. It must still be terminal by the time it returns.
    ///
    /// The pass reports when it starts running, so the close is submitted while that pass demonstrably owns
    /// the queue — the order under test is constructed here, not left to whichever context the scheduler
    /// happens to reach first. Both assertions are then consequences of `close()` having waited: it cannot
    /// return while the pass ahead of it is still running, and it cannot return with the connection open.
    func testCloseRacingAPassLeavesNoOpenConnection() async throws {
        let progress = PassProgressBox()
        let reconcileStore = DaemonReconcileStore(label: "test.reconcile.race", databasePath: databasePath) { store in
            progress.noteStarted()
            _ = try store.projects()
            progress.noteFinished()
        }
        // Opens the connection, so the WAL stays non-empty until the close checkpoints it.
        try await reconcileStore.runPass()
        XCTAssertFalse(databaseIsCheckpointed(), "A pass should have opened the connection.")

        async let racingPass: Void = reconcileStore.runPass()
        await progress.waitUntilStarted(2)
        reconcileStore.close()

        XCTAssertEqual(progress.finished, 2, "Close must not return while the pass it queued behind is still running.")
        XCTAssertTrue(databaseIsCheckpointed(), "No connection may survive a close that has returned.")
        try await racingPass
    }

    /// SQLite runs a truncating checkpoint when the last connection to a database closes, so an
    /// empty (or never-created) `-wal` sidecar is the observable form of "the connection was
    /// released and its final checkpoint happened". An open connection leaves committed pages
    /// sitting in a non-empty WAL.
    private func databaseIsCheckpointed() -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: databasePath + "-wal")[.size] as? Int else { return true }
        return size == 0
    }
}

private final class LockedRoutesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [CaddyRoute] = []

    func set(_ value: [CaddyRoute]) {
        lock.lock()
        routes = value
        lock.unlock()
    }

    func hosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return routes.map(\.host).sorted()
    }

    func upstream(forHost host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return routes.first { $0.host == host }?.upstream
    }
}

/// Progress reported by a reconcile pass from the store's own queue. `waitUntilStarted` lets a test wait
/// until a particular pass is genuinely running there — so work submitted afterwards is unambiguously
/// queued behind it — and `finished` says how many passes have returned. Continuation-based rather than
/// semaphore-based because the waiting side is an async test, and blocking a cooperative thread to wait on
/// a dispatch queue is exactly the shape that turns an ordering test into a scheduling one.
private final class PassProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var finishedCount = 0
    private var waiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func noteStarted() {
        lock.lock()
        startCount += 1
        let reached = waiters.filter { $0.threshold <= startCount }
        waiters.removeAll { $0.threshold <= startCount }
        lock.unlock()
        for waiter in reached { waiter.continuation.resume() }
    }

    func noteFinished() {
        lock.lock()
        finishedCount += 1
        lock.unlock()
    }

    var finished: Int {
        lock.lock()
        defer { lock.unlock() }
        return finishedCount
    }

    func waitUntilStarted(_ threshold: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if startCount >= threshold {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append((threshold, continuation))
            lock.unlock()
        }
    }
}

private final class LockedFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set(_ newValue: Bool) {
        lock.lock()
        flag = newValue
        lock.unlock()
    }
}

private final class LockedCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
