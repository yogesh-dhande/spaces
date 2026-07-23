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

    /// Records its own construction and (single) teardown in a shared `WatcherCounter`,
    /// with a short blocking `start()` to widen the install window that overlapping
    /// refresh passes race in.
    final class CountingWatcher: FileSystemWatching, @unchecked Sendable {
        private let counter: WatcherCounter
        private let startDelay: TimeInterval
        private let queue = DispatchQueue(label: "test.counting-watcher")
        private let lock = NSLock()
        private var stopped = false

        init(counter: WatcherCounter, startDelay: TimeInterval) {
            self.counter = counter
            self.startDelay = startDelay
            counter.onCreate()
        }

        func start() async throws {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    Thread.sleep(forTimeInterval: self.startDelay)
                    continuation.resume()
                }
            }
        }

        func stop() {
            lock.lock()
            let alreadyStopped = stopped
            stopped = true
            lock.unlock()
            if !alreadyStopped { counter.onStop() }
        }
    }

    /// Waits until `created` has held steady for a short settle window (or the timeout),
    /// then returns the final snapshot. Used to let a burst of refresh passes drain.
    /// The settle window only starts once the first watcher has been created — until then
    /// a still-zero counter is indistinguishable from "not started yet" on a slow runner.
    private static func waitUntilCreatedStable(_ counter: WatcherCounter, timeout: Duration) async -> (created: Int, live: Int) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastCreated = counter.snapshot.created
        var stableSince = clock.now
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            let current = counter.snapshot
            if current.created == 0 {
                // Nothing has been created yet; don't let the stability window start.
                stableSince = clock.now
            } else if current.created == lastCreated {
                if clock.now >= stableSince.advanced(by: .milliseconds(500)) { return current }
            } else {
                lastCreated = current.created
                stableSince = clock.now
            }
        }
        return counter.snapshot
    }

    /// The fd-leak regression: `databaseDidChange` storms fire many overlapping
    /// `refreshWatchers` passes. Each pass must install a given project's watcher at
    /// most once — a concurrent pass must not create a second FSEventStream for a
    /// project already being installed — so watcher (and thus fd) growth stays flat on
    /// a stable project set.
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
        let service = WorktreeDiscoveryService(
            databasePath: databasePath, watcherFactory: { _, _, _ in CountingWatcher(counter: counter, startDelay: 0.05) })

        service.start()
        defer { service.stop() }

        // Storm of overlapping refresh passes while the initial install is in flight.
        for _ in 0..<40 { service.refreshWatchers() }
        let afterFirstStorm = await Self.waitUntilCreatedStable(counter, timeout: .seconds(15))
        #expect(afterFirstStorm.created == projectCount)
        #expect(afterFirstStorm.live == projectCount)

        // A second storm over the now fully-installed set must create nothing new.
        for _ in 0..<40 { service.refreshWatchers() }
        let afterSecondStorm = await Self.waitUntilCreatedStable(counter, timeout: .seconds(10))
        #expect(afterSecondStorm.created == projectCount)
        #expect(afterSecondStorm.live == projectCount)
    }
}
