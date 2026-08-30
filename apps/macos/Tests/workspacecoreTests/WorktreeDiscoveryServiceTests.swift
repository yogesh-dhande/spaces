import Foundation
import Testing

@testable import workspacecore

// Every test here hands the store and the service an explicit database path, and
// `WorktreeDiscoveryService` never resolves a profile, so this suite binds no profile environment. That
// is deliberate: `.serialized` orders tests only within a suite, and Swift Testing runs distinct suites
// concurrently in one process, so a suite that mutated the process-global `SPACES_*` here could be
// clobbered by — and could clobber — a sibling suite.
@Suite struct WorktreeDiscoveryServiceTests {
    /// Stand-in for a real watcher whose FSEvents/inotify setup is stalled by a busy
    /// system: `start()` blocks a background thread for `delay` (never the main actor)
    /// and signals when it has entered the blocking region, so the test can measure
    /// main-actor responsiveness while a watcher install is in flight.
    final class BlockingStartWatcher: FileSystemWatching, @unchecked Sendable {
        private let delay: TimeInterval
        private let onStartEntered: @Sendable () -> Void
        private let queue = DispatchQueue(label: "test.blocking-start-watcher")
        private let lock = NSLock()
        private var finishedStart = false

        init(delay: TimeInterval, onStartEntered: @escaping @Sendable () -> Void) {
            self.delay = delay
            self.onStartEntered = onStartEntered
        }

        /// Set on the background queue right before `continuation.resume()`, so the test
        /// can tell "start() is still blocked" from "start() returned" without racing the
        /// continuation itself.
        var hasFinishedStart: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finishedStart
        }

        func start() async throws {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    self.onStartEntered()
                    Thread.sleep(forTimeInterval: self.delay)
                    self.lock.lock()
                    self.finishedStart = true
                    self.lock.unlock()
                    continuation.resume()
                }
            }
        }

        func stop() {}
    }

    /// The freeze this guards against: the daemon's main actor is its terminal-I/O
    /// engine, and installing a git-project watcher used to run the (slow, IPC-bound)
    /// FSEvents setup synchronously on it. Installs now suspend across the watcher's
    /// `start()`, so a stalled install must not stall the main actor. A regressed
    /// install that awaited `start()` while holding the main actor would still be
    /// sitting on that await when the round-trips below try to run, so they could not
    /// complete until `start()` returned — completing them while `start()` is
    /// unmistakably still blocked is the proof, with no wall-clock bound needed.
    @MainActor @Test func slowWatcherInstallKeepsMainActorResponsive() async throws {
        let repo = try makeTempGitRepo(name: "repo")
        let databaseDirectory = try makeTempDirectory()
        let databasePath = databaseDirectory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: databasePath)
        try store.upsert(project: ProjectRecord(id: "p1", name: "repo", dir: repo.path, isGitRepo: true, defaultBranch: "main"))

        // Wall clock can't tell a captive main actor from ordinary scheduler starvation:
        // Swift Testing runs many sibling @MainActor suites concurrently in one process,
        // so on a loaded CI runner the round-trips below can queue behind unrelated
        // main-actor work for well over the old 500ms bound even though this watcher
        // install never touched the main actor. Block for 20s instead: long enough that
        // starvation can't plausibly outlast it, and check ordering (start() still
        // blocked) rather than elapsed time.
        let blockingDelay: TimeInterval = 20
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let watcher = BlockingStartWatcher(delay: blockingDelay) { enteredContinuation.yield() }
        let service = WorktreeDiscoveryService(databasePath: databasePath, watcherFactory: { _, _, _ in watcher })

        service.start()
        defer { service.stop() }

        // Wait until the watcher install has entered its blocking start().
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        // With the install stalled on a background thread, the main actor must stay
        // free: several round-trips through its executor complete on their own.
        for _ in 0..<5 { await Task { @MainActor in }.value }

        // Proof that the round-trips above did not simply wait out the install: start()
        // has not returned yet.
        #expect(watcher.hasFinishedStart == false)
    }

    /// Thread-safe tally of watchers built by the injected factory. `created` counts
    /// every watcher object the service constructs; `live` tracks created-minus-stopped.
    final class WatcherCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var createdCount = 0
        private var liveCount = 0

        func onCreate() {
            lock.lock()
            defer { lock.unlock() }
            createdCount += 1
            liveCount += 1
        }

        func onStop() {
            lock.lock()
            defer { lock.unlock() }
            liveCount -= 1
        }

        var snapshot: (created: Int, live: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (createdCount, liveCount)
        }
    }

    /// Parks every `start()` call on a continuation instead of sleeping, and lets the test release
    /// every parked call at once via `releaseAll()`. This is what lets the storm test hold N watcher
    /// installs open for exactly as long as it needs — no timing assumption about how long an
    /// install "should" take, and no thread blocked while parked (a `CheckedContinuation` suspends
    /// cooperatively).
    final class WatcherStartGate: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func park() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                pending.append(continuation)
                lock.unlock()
            }
        }

        func releaseAll() {
            lock.lock()
            released = true
            let toResume = pending
            pending.removeAll()
            lock.unlock()
            for continuation in toResume { continuation.resume() }
        }
    }

    /// Thread-safe tally of `start()` calls that have parked, paired with an `AsyncStream` the test
    /// awaits instead of polling: each park yields the cumulative count, so a consumer can stop the
    /// instant its target is reached rather than sampling on an interval.
    final class ParkedWatcherTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let continuation: AsyncStream<Int>.Continuation
        let parkedCounts: AsyncStream<Int>

        init() { (parkedCounts, continuation) = AsyncStream<Int>.makeStream() }

        func recordParked() {
            lock.lock()
            count += 1
            let current = count
            lock.unlock()
            continuation.yield(current)
        }
    }

    /// Records its own construction and (single) teardown in a shared `WatcherCounter`, and parks
    /// every `start()` call in a shared `WatcherStartGate` (recording the park in a
    /// `ParkedWatcherTracker` first) so the test can construct the storm's race deterministically
    /// instead of sampling it under a sleep.
    final class CountingWatcher: FileSystemWatching, @unchecked Sendable {
        private let counter: WatcherCounter
        private let tracker: ParkedWatcherTracker
        private let gate: WatcherStartGate
        private let lock = NSLock()
        private var stopped = false

        init(counter: WatcherCounter, tracker: ParkedWatcherTracker, gate: WatcherStartGate) {
            self.counter = counter
            self.tracker = tracker
            self.gate = gate
            counter.onCreate()
        }

        func start() async throws {
            tracker.recordParked()
            await gate.park()
        }

        func stop() {
            lock.lock()
            let alreadyStopped = stopped
            stopped = true
            lock.unlock()
            if !alreadyStopped { counter.onStop() }
        }
    }

    /// Awaits `tracker.parkedCounts` until `target` parked watchers have been observed, racing that
    /// against `timeout`. The race exists only to turn a genuine regression (fewer watchers ever
    /// park than expected) into a reported failure instead of a hang; on success the target is
    /// always reached the instant the `target`-th watcher parks, so `timeout` is never approached.
    /// `AsyncStream.next()` honors cancellation, so cancelling the losing branch below does not
    /// leak a suspended task.
    private static func waitUntilParked(atLeast target: Int, tracker: ParkedWatcherTracker, timeout: Duration = .seconds(30)) async -> Int {
        await withTaskGroup(of: Int.self) { group in
            group.addTask {
                var iterator = tracker.parkedCounts.makeAsyncIterator()
                var latest = 0
                while latest < target, let next = await iterator.next() { latest = next }
                return latest
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return 0
            }
            let first = await group.next() ?? 0
            group.cancelAll()
            return first
        }
    }

    /// The fd-leak regression: `databaseDidChange` storms fire many overlapping
    /// `refreshWatchers` passes. Each pass must install a given project's watcher at
    /// most once — a concurrent pass must not create a second FSEventStream for a
    /// project already being installed — so watcher (and thus fd) growth stays flat on
    /// a stable project set.
    ///
    /// The race is constructed rather than sampled. `refreshWatchers()`'s per-project loop is
    /// sequential — a single call can only ever suspend installing *one* project, since the next
    /// iteration does not begin until the current `await installWatcher(...)` returns — so reaching
    /// all `projectCount` watchers stalled mid-install at once requires more than one pass alive
    /// concurrently: each new pass's loop synchronously skips whatever a prior pass already claimed
    /// (via `installingProjectIDs`) and stalls on the next unclaimed project instead. The storm is
    /// therefore fired immediately after `start()`, with no `await` in between, so all 41 passes
    /// exist before any of them makes progress; only then does the test wait for proof (via
    /// `ParkedWatcherTracker`, not a poll) that exactly `projectCount` installs are genuinely
    /// in flight — confirming the storm claimed every project exactly once with none left over and
    /// none duplicated. `WorktreeDiscoveryService.drainInFlightWorkForTesting()` then makes "the
    /// storm has fully settled" an awaitable fact instead of a stability guess, so the assertions
    /// that follow are exact rather than "no change observed for N ms".
    @MainActor @Test func refreshStormDoesNotDuplicateWatchers() async throws {
        let databaseDirectory = try makeTempDirectory()
        let databasePath = databaseDirectory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: databasePath)
        let projectCount = 4
        for index in 0..<projectCount {
            let repo = try makeTempGitRepo(name: "repo-\(index)")
            try store.upsert(project: ProjectRecord(id: "p\(index)", name: "repo-\(index)", dir: repo.path, isGitRepo: true, defaultBranch: "main"))
        }

        let counter = WatcherCounter()
        let tracker = ParkedWatcherTracker()
        let gate = WatcherStartGate()
        let service = WorktreeDiscoveryService(
            databasePath: databasePath, watcherFactory: { _, _, _ in CountingWatcher(counter: counter, tracker: tracker, gate: gate) })

        // `start()` fires one refreshWatchers pass; storming immediately afterward (before awaiting
        // anything) is what lets the interleaved passes collectively reach every project.
        service.start()
        defer { service.stop() }
        for _ in 0..<40 { service.refreshWatchers() }

        // Wait for proof that all projectCount installs are genuinely stalled mid-`start()` — the
        // window the regression (a duplicate FSEventStream for a project another pass is already
        // installing) needs to be reachable at all.
        let parkedAfterFirstStorm = await Self.waitUntilParked(atLeast: projectCount, tracker: tracker)
        #expect(parkedAfterFirstStorm == projectCount)

        // Release the stalled installs and drain every task the service spawned — the storm's
        // passes, the now-unblocked installs, and any scans they enqueue — so the snapshot below
        // reflects a fully quiesced service.
        gate.releaseAll()
        await service.drainInFlightWorkForTesting()

        let afterFirstStorm = counter.snapshot
        #expect(afterFirstStorm.created == projectCount)
        #expect(afterFirstStorm.live == projectCount)

        // A second storm over the now fully-installed set must create nothing new: every pass's
        // loop finds `watchers[projectID] != nil` for all `projectCount` projects and returns
        // without ever reaching the factory.
        for _ in 0..<40 { service.refreshWatchers() }
        await service.drainInFlightWorkForTesting()

        let afterSecondStorm = counter.snapshot
        #expect(afterSecondStorm.created == projectCount)
        #expect(afterSecondStorm.live == projectCount)
    }

    /// Records its construction and (single) teardown in a shared `WatcherCounter` and either
    /// starts cleanly or fails the way a real watcher does when the OS refuses its event stream.
    /// The injected factory is the seam these quarantine tests observe: the service builds exactly
    /// one watcher per real install attempt, so the counter reports install attempts without the
    /// service carrying a counter of its own.
    final class StubWatcher: FileSystemWatching, @unchecked Sendable {
        private let counter: WatcherCounter
        private let startError: (any Error)?
        private let lock = NSLock()
        private var stopped = false

        init(counter: WatcherCounter, startError: (any Error)?) {
            self.counter = counter
            self.startError = startError
            counter.onCreate()
        }

        func start() async throws { if let startError { throw startError } }

        func stop() {
            lock.lock()
            let alreadyStopped = stopped
            stopped = true
            lock.unlock()
            if !alreadyStopped { counter.onStop() }
        }
    }

    /// Counts the watcher-stream failures the service reports through `onError`, ignoring any other
    /// error (e.g. a scan failure) so the tally measures exactly the log line the storm produced.
    final class StreamFailureTally: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record(_ error: any Error) {
            guard let watchError = error as? FileSystemWatcher.WatchError, case .streamUnavailable = watchError else { return }
            lock.lock()
            count += 1
            lock.unlock()
        }

        var reported: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// The retry storm: a project whose watcher stream cannot be created used to be re-attempted by
    /// every `databaseDidChange`-driven refresh pass — a git spawn, a watcher create, and an error
    /// report each time, forever. One failure must cost one attempt and one report, and the failure
    /// must not disturb the projects that watch fine.
    ///
    /// The unwatchable project's directory exists throughout (this is the FSEvents
    /// capacity-exhaustion shape), so a reachability probe keeps answering "reachable" — the case
    /// that must specifically not re-arm, or the storm returns.
    @MainActor @Test func unwatchableProjectIsAttemptedOnceAndLeavesOtherProjectsWatched() async throws {
        let healthyRepo = try makeTempGitRepo(name: "healthy")
        let unwatchableRepo = try makeTempGitRepo(name: "unwatchable")
        let databaseDirectory = try makeTempDirectory()
        let databasePath = databaseDirectory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: databasePath)
        try store.upsert(project: ProjectRecord(id: "healthy", name: "healthy", dir: healthyRepo.path, isGitRepo: true, defaultBranch: "main"))
        try store.upsert(
            project: ProjectRecord(id: "unwatchable", name: "unwatchable", dir: unwatchableRepo.path, isGitRepo: true, defaultBranch: "main"))

        let healthyCounter = WatcherCounter()
        let unwatchableCounter = WatcherCounter()
        let failures = StreamFailureTally()
        // The factory only sees the watched directories, so the project is identified by its git
        // common dir living under the repo (symlink-resolved, since the service standardizes it).
        let unwatchablePrefix = unwatchableRepo.resolvingSymlinksInPath().path + "/"
        let service = WorktreeDiscoveryService(
            databasePath: databasePath, onError: { failures.record($0) },
            watcherFactory: { paths, _, _ in
                let isUnwatchable = paths.contains { $0.hasPrefix(unwatchablePrefix) }
                return StubWatcher(
                    counter: isUnwatchable ? unwatchableCounter : healthyCounter,
                    startError: isUnwatchable ? FileSystemWatcher.WatchError.streamUnavailable : nil)
            })

        service.start()
        defer { service.stop() }
        await service.drainInFlightWorkForTesting()

        #expect(unwatchableCounter.snapshot.created == 1)
        #expect(healthyCounter.snapshot.live == 1)
        #expect(failures.reported == 1)

        for _ in 0..<20 {
            service.refreshWatchers()
            await service.drainInFlightWorkForTesting()
        }

        #expect(unwatchableCounter.snapshot.created == 1)
        #expect(failures.reported == 1)
        #expect(healthyCounter.snapshot.created == 1)
        #expect(healthyCounter.snapshot.live == 1)
    }

    /// The recovery half of the quarantine: a registered project whose directory is gone (deleted,
    /// or on an unmounted volume) cannot be watched, but must start being watched again on its own
    /// once the directory is back — no user action and no daemon restart. Recovery lands on the
    /// first refresh pass after the directory returns, which is why the quarantine re-arms on a
    /// cheap reachability check rather than waiting for a restart.
    @MainActor @Test func projectIsWatchedAgainWhenItsDirectoryReturns() async throws {
        let repo = try makeTempGitRepo(name: "repo")
        let databaseDirectory = try makeTempDirectory()
        let databasePath = databaseDirectory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: databasePath)
        try store.upsert(project: ProjectRecord(id: "p1", name: "repo", dir: repo.path, isGitRepo: true, defaultBranch: "main"))
        try FileManager.default.removeItem(at: repo)

        let counter = WatcherCounter()
        let service = WorktreeDiscoveryService(
            databasePath: databasePath, watcherFactory: { _, _, _ in StubWatcher(counter: counter, startError: nil) })

        service.start()
        defer { service.stop() }
        await service.drainInFlightWorkForTesting()
        for _ in 0..<10 {
            service.refreshWatchers()
            await service.drainInFlightWorkForTesting()
        }
        #expect(counter.snapshot.created == 0)

        try initializeGitRepository(at: repo)
        service.refreshWatchers()
        await service.drainInFlightWorkForTesting()

        #expect(counter.snapshot.created == 1)
        #expect(counter.snapshot.live == 1)
    }
}
