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
            id: "workspace-router", projectID: project.id, dir: "/projects/router", dirname: nil, branch: nil, isDefault: false, isRunning: false,
            lastLaunchedAt: nil)
        try seedStore.upsert(workspace: workspace)
        try seedStore.setWorkspacePorts(workspaceID: workspace.id, ports: [21001], names: ["web"])

        let observedRoutes = LockedRoutesBox()
        let reconcileStore = DaemonReconcileStore(label: "test.reconcile.routes", databasePath: databasePath) { store in
            observedRoutes.set(try WorkspaceOrchestrator(store: store).caddyRouteTable())
        }
        addTeardownBlock { await reconcileStore.close() }

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
        addTeardownBlock { await reconcileStore.close() }

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

        await reconcileStore.close()
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

        await reconcileStore.close()
        await reconcileStore.close()
        try await reconcileStore.runPass()

        XCTAssertEqual(passCount.value, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath), "Close must not create the database.")
    }

    /// `close()` submitted while a pass is running is the harder of the two queue orders: the close lands
    /// behind work that still holds the connection. It must be terminal by the time it returns, and it must
    /// reach that point by suspending its caller rather than by holding the caller's thread.
    ///
    /// Both properties come out of one constructed interleaving, and the gate is what constructs it. The
    /// racing pass reports that it started and then parks on the gate, so it is provably still running — it
    /// cannot have released the store's queue — for as long as the gate is held. The only thing that opens
    /// the gate is a block enqueued on the MAIN queue before the close is called. This test is
    /// `@MainActor`, so that block cannot run inside the same main-actor turn that submits it: it runs only
    /// once the close yields the main actor.
    ///
    /// That makes each assertion a fact rather than a hope:
    /// - A close that returns without waiting returns while the gate is still shut, so it observes an
    ///   unfinished pass and an open connection.
    /// - A close that waits by BLOCKING the main thread never lets the gate open at all. It is the shape
    ///   the daemon must not have: a reconcile pass can reach the process-wide terminal terminator, which
    ///   enters the terminal engine actor, which may hop synchronously back to main. The gate's wait is
    ///   bounded so that shape fails this test with `mainQueueRanDuringClose` false instead of hanging the
    ///   suite the way the real three-way deadlock would.
    @MainActor func testCloseBehindARunningPassYieldsTheMainActorAndLeavesNoOpenConnection() async throws {
        let progress = PassProgressBox()
        let gate = PassGate()
        let reconcileStore = DaemonReconcileStore(label: "test.reconcile.race", databasePath: databasePath) { store in
            progress.noteStarted()
            gate.waitUntilOpened()
            _ = try store.projects()
            progress.noteFinished()
        }
        // Opens the connection, so the WAL stays non-empty until the close checkpoints it. The gate starts
        // open so this priming pass runs straight through.
        gate.open()
        try await reconcileStore.runPass()
        XCTAssertFalse(databaseIsCheckpointed(), "A pass should have opened the connection.")

        gate.shut()
        async let racingPass: Void = reconcileStore.runPass()
        await progress.waitUntilStarted(2)

        // Enqueued while this main-actor test still owns the main actor, so it cannot run until the close
        // below yields it. Nothing else opens the gate the racing pass is parked on.
        let mainQueueRanDuringClose = LockedFlagBox()
        DispatchQueue.main.async {
            mainQueueRanDuringClose.set(true)
            gate.open()
        }
        await reconcileStore.close()

        XCTAssertTrue(
            mainQueueRanDuringClose.value,
            "Close must suspend the main actor while it waits, not hold its thread: main-queue work enqueued before the close has to run while it waits."
        )
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

/// Parks a reconcile pass on the store's own queue until the test opens it, so "a close submitted while a
/// pass is still running" is a constructed fact rather than a hoped-for scheduling outcome. Blocking is the
/// point: the pass body runs on the store's private serial queue, and holding that queue is the state under
/// test. The wait is bounded so that a `close()` which blocks its caller's thread — leaving nothing able to
/// open the gate — fails its test with a diagnosis rather than hanging the suite.
private final class PassGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = true

    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }

    func shut() {
        condition.lock()
        opened = false
        condition.unlock()
    }

    func waitUntilOpened() {
        let deadline = Date().addingTimeInterval(10)
        condition.lock()
        while !opened, Date() < deadline { condition.wait(until: deadline) }
        condition.unlock()
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
