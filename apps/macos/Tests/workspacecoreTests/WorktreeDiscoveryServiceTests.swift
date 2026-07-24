import Foundation
import Testing

@testable import workspacecore

@Suite struct WorktreeDiscoveryServiceTests {
    /// Stand-in for a real watcher whose FSEvents/inotify setup is stalled by a busy
    /// system: `start()` blocks a background thread for `delay` (never the main actor)
    /// and signals when it has entered the blocking region, so the test can measure
    /// main-actor responsiveness while a watcher install is in flight.
    final class BlockingStartWatcher: FileSystemWatching, @unchecked Sendable {
        private let delay: TimeInterval
        private let onStartEntered: @Sendable () -> Void
        private let queue = DispatchQueue(label: "test.blocking-start-watcher")

        init(delay: TimeInterval, onStartEntered: @escaping @Sendable () -> Void) {
            self.delay = delay
            self.onStartEntered = onStartEntered
        }

        func start() async throws {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    self.onStartEntered()
                    Thread.sleep(forTimeInterval: self.delay)
                    continuation.resume()
                }
            }
        }

        func stop() {}
    }

    /// The freeze this guards against: the daemon's main actor is its terminal-I/O
    /// engine, and installing a git-project watcher used to run the (slow, IPC-bound)
    /// FSEvents setup synchronously on it. Installs now suspend across the watcher's
    /// `start()`, so a stalled install must not stall the main actor.
    @MainActor @Test func slowWatcherInstallKeepsMainActorResponsive() async throws {
        let repo = try makeTempGitRepo(name: "repo")
        let databaseDirectory = try makeTempDirectory()
        let databasePath = databaseDirectory.appendingPathComponent("spaces.db").path
        let store = try SQLiteStore(path: databasePath)
        try store.upsert(project: ProjectRecord(id: "p1", name: "repo", dir: repo.path, isGitRepo: true, defaultBranch: "main"))

        // Block far longer than the responsiveness bound we assert, so a main-actor
        // stall would be unmistakable rather than a tight-margin flake.
        let blockingDelay: TimeInterval = 2
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let service = WorktreeDiscoveryService(
            databasePath: databasePath, watcherFactory: { _, _, _ in BlockingStartWatcher(delay: blockingDelay) { enteredContinuation.yield() } })

        service.start()
        defer { service.stop() }

        // Wait until the watcher install has entered its blocking start().
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        // With the install stalled on a background thread, the main actor must stay
        // free: several round-trips through its executor complete in a fraction of the
        // blocking delay.
        let clock = ContinuousClock()
        let elapsed = await clock.measure { for _ in 0..<5 { await Task { @MainActor in }.value } }
        #expect(elapsed < .milliseconds(500))
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

        init() {
            (parkedCounts, continuation) = AsyncStream<Int>.makeStream()
        }

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
}
