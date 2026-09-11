import Foundation
import Testing
import spacesruntimecore
import workspacecore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@testable import spacesdeviceapi

/// A fake `FileSystemWatcher` stand-in: records its constructor's `paths`, captures the `onChange`
/// closure so a test can fire synthetic filesystem events, and lets a test script `start()` to succeed or
/// fail (once, or every time).
private final class FakeWatcher: FileSystemWatching, @unchecked Sendable {
    let paths: [String]
    let onChange: @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
    private let startResults: [Result<Void, any Error>]
    private let lock = NSLock()
    private var startAttempt = 0
    private(set) var stopped = false
    private(set) var addedPaths: [[String]] = []

    /// `startResults` is consumed one per `start()` call; the last entry repeats once exhausted, so a
    /// caller that only cares about "always succeeds" or "always fails" passes a single-element array.
    init(paths: [String], onChange: @escaping @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void, startResults: [Result<Void, any Error>]) {
        self.paths = paths
        self.onChange = onChange
        self.startResults = startResults
    }

    func start() async throws {
        let result = lock.withLock {
            let index = min(startAttempt, startResults.count - 1)
            startAttempt += 1
            return startResults[index]
        }
        try result.get()
    }

    func stop() { stopped = true }

    func addPaths(_ paths: [String]) {
        lock.lock()
        addedPaths.append(paths)
        lock.unlock()
    }
}

private struct FakeStartError: Error, CustomStringConvertible {
    let description: String
}

/// Hands out one `start()` result per install *attempt*, not per `FakeWatcher` instance: a failed install
/// discards its watcher (see `WorkspaceWatch.attemptInstallLocked`) and asks the factory for a brand new
/// one on the next attempt, so a plain per-instance `startResults` array would restart at its first entry
/// every time and never reach the later, successful entry. This persists the cursor across every
/// `FakeWatcher` one factory closure constructs for the same `WorkspaceWatch`.
private final class WatcherStartScript: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let results: [Result<Void, any Error>]

    init(_ results: [Result<Void, any Error>]) { self.results = results }

    func next() -> Result<Void, any Error> {
        lock.lock()
        defer { lock.unlock() }
        let result = results[min(index, results.count - 1)]
        index += 1
        return result
    }
}

/// Builds a minimal real git repository so `WorkspaceWatch`'s install path (repository-map discovery,
/// ignore-set reads) has something real to run against; the filesystem watcher itself is always the fake
/// above, so no FSEvents/inotify machinery is exercised here.
/// Fixture roots are handed out in `realpath` form (`/private/var/...` on macOS, where the default
/// temporary directory is itself a symlink), because that is the spelling a real FSEvents or inotify
/// watcher reports and the form `WorkspaceWatch` resolves its root to; a fake watcher firing the
/// symlinked spelling would be modelling an event no real watcher ever delivers.
private func resolvedTemporaryDirectory() -> URL {
    let temporary = FileManager.default.temporaryDirectory.path
    guard let resolved = realpath(temporary, nil) else { return URL(fileURLWithPath: temporary, isDirectory: true) }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

@discardableResult private func makeWorkspaceRepository() throws -> URL {
    let root = resolvedTemporaryDirectory().appendingPathComponent("spaces-workspace-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runGit(["init", "--initial-branch", "main"], cwd: root.path)
    try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try runGit(["add", "-A"], cwd: root.path)
    try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: root.path)
    return root
}

/// A real git repository (like `makeWorkspaceRepository`) whose committed `.gitignore` covers a `build/`
/// directory, so a `build` directory created after install exercises the classify-before-accept path:
/// `WorkspaceWatch` must add it to the repository's ignore set before the acceptance pass judges its own
/// creation event and the writes that follow inside it.
@discardableResult private func makeWorkspaceRepositoryIgnoringBuildDirectory() throws -> URL {
    let root = resolvedTemporaryDirectory().appendingPathComponent(
        "spaces-workspace-watch-ignored-dir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runGit(["init", "--initial-branch", "main"], cwd: root.path)
    try "build/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try runGit(["add", "-A"], cwd: root.path)
    try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: root.path)
    return root
}

/// A plain project directory with no `git init` at all, exercising the non-git workspace shape
/// `WorkspaceWatch.discoverRepositoryMap` treats as a single ungated repository-map entry.
private func makeNonGitWorkspace() throws -> URL {
    let root = resolvedTemporaryDirectory().appendingPathComponent("spaces-workspace-watch-nongit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A main checkout plus a worktree linked to it via `git worktree add`: the linked worktree's own `gitDir`
/// is `<main>/.git/worktrees/<name>`, while its `commonDir` is `<main>/.git` itself, the shape
/// `refreshIgnoreSetIfGitignoreChanged`'s `<commonDir>/info/exclude` handling (as opposed to
/// `<gitDir>/info/exclude`, which does not exist for a linked worktree) exists for.
private func makeLinkedWorktreeRepository() throws -> (main: URL, worktree: URL, commonDir: URL) {
    let main = resolvedTemporaryDirectory().appendingPathComponent(
        "spaces-workspace-watch-worktree-main-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
    try runGit(["init", "--initial-branch", "main"], cwd: main.path)
    try "hello".write(to: main.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try runGit(["add", "-A"], cwd: main.path)
    try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: main.path)
    let worktree = resolvedTemporaryDirectory().appendingPathComponent(
        "spaces-workspace-watch-worktree-linked-\(UUID().uuidString)", isDirectory: true)
    try runGit(["worktree", "add", "-b", "feature", worktree.path], cwd: main.path)
    return (main, worktree, main.appendingPathComponent(".git"))
}

/// A superproject with one initialized submodule (`sub`) whose own committed `.gitignore` covers a
/// `build/` directory: exercises a directory created inside a submodule being classified against the
/// submodule's OWN ignore rules, not the superproject's (whose `ls-files` never lists a path under a
/// gitlink). `protocol.file.allow=always` is required for a local
/// filesystem submodule URL since git 2.38.1 (CVE-2022-39253 hardening); real users add submodules from
/// https/ssh remotes, where this default does not apply.
private func makeWorkspaceRepositoryWithSubmoduleIgnoringBuildDirectory() throws -> (container: URL, superRoot: URL, submoduleWorkingDir: URL) {
    let container = resolvedTemporaryDirectory().appendingPathComponent(
        "spaces-workspace-watch-submodule-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

    let subSource = container.appendingPathComponent("sub-source", isDirectory: true)
    try FileManager.default.createDirectory(at: subSource, withIntermediateDirectories: true)
    try runGit(["init", "--initial-branch", "main"], cwd: subSource.path)
    try "build/\n".write(to: subSource.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try "hello".write(to: subSource.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try runGit(["add", "-A"], cwd: subSource.path)
    try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: subSource.path)

    let superRoot = container.appendingPathComponent("super", isDirectory: true)
    try FileManager.default.createDirectory(at: superRoot, withIntermediateDirectories: true)
    try runGit(["init", "--initial-branch", "main"], cwd: superRoot.path)
    try "hello".write(to: superRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try runGit(["-c", "protocol.file.allow=always", "submodule", "add", "-q", subSource.path, "sub"], cwd: superRoot.path)
    try runGit(["add", "-A"], cwd: superRoot.path)
    try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: superRoot.path)

    return (container, superRoot, superRoot.appendingPathComponent("sub", isDirectory: true))
}

@discardableResult private func runGit(_ arguments: [String], cwd: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    var environment = ProcessInfo.processInfo.environment
    for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] { environment.removeValue(forKey: key) }
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

/// `.serialized`: every test here calls `subscribe`, which blocks the calling thread on `queue.sync` ->
/// `attemptInstallLocked` -> `runBlocking` -> `semaphore.wait()` while `runBlocking`'s inner `Task` needs a
/// cooperative-pool thread to run the fake watcher's `start()`. Swift Testing runs each async test body on
/// that same pool, so once as many tests as the pool has cores are blocked in `subscribe` at once, no
/// thread is left free to run any of their `runBlocking` tasks and the whole process deadlocks. The daemon
/// itself never calls `subscribe` from the cooperative pool (only from a caller's own `streamQueue`, per
/// `runBlocking`'s own doc comment), so this is a test-harness hazard, not a product one; serializing this
/// suite keeps it at one `subscribe` call in flight at a time.
@Suite(.serialized) struct SpacesDeviceWorkspaceWatchTests {
    /// Waits until `predicate` is true or `timeout` elapses, polling on a short interval: used to await a
    /// debounce firing that runs asynchronously on `WorkspaceWatch`'s own queue.
    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func subscribeReportsNoErrorWhenTheWatcherStartsCleanly() throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(),
            watcherFactory: { paths, onChange in FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())]) })

        let (token, error) = watch.subscribe { _ in }
        #expect(error == nil)
        watch.unsubscribe(token)
    }

    @Test func subscribeReportsTheOSErrorTextWhenTheWatcherFailsToStart() throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(),
            watcherFactory: { paths, onChange in
                FakeWatcher(paths: paths, onChange: onChange, startResults: [.failure(FakeStartError(description: "too many open files"))])
            })

        let (token, error) = watch.subscribe { _ in }
        #expect(error?.contains("too many open files") == true)
        watch.unsubscribe(token)
    }

    // A new subscriber joining a watch that is in the failed state retries the whole install (not just
    // the watcher's own `start()`), and a subsequent success clears the error for that new subscription's
    // frames. Covered in both subscriber orderings: the first
    // subscriber gone before the second joins (the watch drops to zero subscribers and back up), and the
    // first subscriber still attached when the second joins (the web's Retry button re-subscribes both
    // streams, so the still-attached stream's subscription can outlive the failed one's).
    @Test func aNewSubscriberRetriesAFailedWatchAndClearsTheErrorOnSuccessAfterTheFirstSubscriberLeaves() throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = WatcherStartScript([.failure(FakeStartError(description: "watch limit reached")), .success(())])
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(),
            watcherFactory: { paths, onChange in FakeWatcher(paths: paths, onChange: onChange, startResults: [script.next()]) })

        let (firstToken, firstError) = watch.subscribe { _ in }
        #expect(firstError?.contains("watch limit reached") == true)
        watch.unsubscribe(firstToken)

        let (secondToken, secondError) = watch.subscribe { _ in }
        #expect(secondError == nil)
        watch.unsubscribe(secondToken)
    }

    // A retry that reinstalls the SHARED watch only recomputes the subscriber that triggered it: without
    // forcing a broadcast, every OTHER attached subscription (whose own handler is still holding the
    // stale failed signature) would keep reporting the old error on its own keepalive cadence, flapping
    // between error and healthy frames instead of clearing once the watch actually recovers.
    @Test func aNewSubscriberRetriesAFailedWatchAndClearsTheErrorWhileTheFirstSubscriberIsStillAttached() async throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = WatcherStartScript([.failure(FakeStartError(description: "watch limit reached")), .success(())])
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.05, debounceCeiling: 2,
            watcherFactory: { paths, onChange in FakeWatcher(paths: paths, onChange: onChange, startResults: [script.next()]) })

        final class Firings: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [WorkspaceWatch.Touched] = []
            func record(_ touched: WorkspaceWatch.Touched) {
                lock.lock()
                recorded.append(touched)
                lock.unlock()
            }
            var all: [WorkspaceWatch.Touched] {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }
        }
        let firstFirings = Firings()

        let (firstToken, firstError) = watch.subscribe { firstFirings.record($0) }
        #expect(firstError?.contains("watch limit reached") == true)

        // The second subscriber's own retry reinstalls the shared watch; the first subscriber never
        // re-subscribes on its own, so it must learn of the recovery through the forced broadcast.
        let (secondToken, secondError) = watch.subscribe { _ in }
        #expect(secondError == nil)

        await waitUntil { !firstFirings.all.isEmpty }
        #expect(firstFirings.all.contains { $0.all == true })
        #expect(watch.currentStartError() == nil)

        watch.unsubscribe(firstToken)
        watch.unsubscribe(secondToken)
    }

    /// `SpacesDeviceAPIServer.acquireWorkspaceWatch` keeps a workspace's `WorkspaceWatch` for the
    /// daemon's life once created, never removing it on a last unsubscribe (see that function's doc
    /// comment for why removal could not be made race-free). This exercises the contract that design
    /// relies on directly: a watch left with zero subscribers is not discarded, but its next `subscribe`
    /// still reinstalls a genuinely new watcher (`unsubscribe`'s own doc comment: "the next `subscribe`
    /// after that starts a fresh install from scratch"), exactly as if it were a brand-new instance.
    @Test func aWatchWhoseLastSubscriberLeftReinstallsOnTheNextSubscribe() throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        // Plain reference-type boxes, matching this file's own `WatcherBox` idiom elsewhere: `subscribe`
        // and `unsubscribe` are synchronous, `queue.sync`-confined calls, so nothing here actually runs
        // concurrently with the test body, but a `@Sendable` closure still cannot capture a local `var`
        // directly, only mutate a property through a captured reference.
        final class Counter: @unchecked Sendable { var value = 0 }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }

        let factoryInvocations = Counter()
        let watcherBox = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(),
            watcherFactory: { paths, onChange in
                factoryInvocations.value += 1
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                watcherBox.watcher = watcher
                return watcher
            })

        let (tokenA, errorA) = watch.subscribe { _ in }
        #expect(errorA == nil)
        #expect(factoryInvocations.value == 1)
        let firstWatcher = try #require(watcherBox.watcher)

        let (tokenB, errorB) = watch.subscribe { _ in }
        #expect(errorB == nil)
        #expect(factoryInvocations.value == 1, "a second subscriber joining an already-healthy watch must not trigger another install")

        watch.unsubscribe(tokenA)
        #expect(firstWatcher.stopped == false, "one remaining subscriber must keep the watch alive")

        watch.unsubscribe(tokenB)
        #expect(firstWatcher.stopped == true, "the watcher must be stopped once the last subscriber leaves")

        let (tokenC, errorC) = watch.subscribe { _ in }
        #expect(errorC == nil)
        #expect(factoryInvocations.value == 2, "a subscriber arriving after every prior one left must trigger a fresh install")
        watch.unsubscribe(tokenC)
    }

    @Test func fiveEventsWithinTheDebounceWindowFireOnceWithTheCombinedTouchedSet() async throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.05, debounceCeiling: 2,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class Firings: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [WorkspaceWatch.Touched] = []
            func record(_ touched: WorkspaceWatch.Touched) {
                lock.lock()
                recorded.append(touched)
                lock.unlock()
            }
            var all: [WorkspaceWatch.Touched] {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }
        }
        let firings = Firings()
        let (token, error) = watch.subscribe { firings.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }

        let readme = root.appendingPathComponent("README.md").path
        for _ in 0..<5 { box.watcher?.onChange([readme], false) }

        await waitUntil { !firings.all.isEmpty }
        #expect(firings.all.count == 1)
        #expect(firings.all.first?.directories == [root.path])
        #expect(firings.all.first?.all == false)
    }

    @Test func continuousEventsFireAtTheDebounceCeilingRatherThanNeverFiring() async throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.1, debounceCeiling: 0.3,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class FiringCount: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        let firingCount = FiringCount()
        let (token, _) = watch.subscribe { _ in firingCount.increment() }
        defer { watch.unsubscribe(token) }

        let readme = root.appendingPathComponent("README.md").path
        let burstEnd = Date().addingTimeInterval(0.5)
        while Date() < burstEnd {
            box.watcher?.onChange([readme], false)
            try await Task.sleep(for: .milliseconds(50))
        }

        // A continuous burst past the 0.3s ceiling must have fired at least once before the burst ended
        // (each event re-arms a 0.1s timer, which never elapses on its own under continuous events; only
        // the ceiling forces a firing mid-burst).
        await waitUntil { firingCount.value >= 1 }
        #expect(firingCount.value >= 1)
    }

    /// A rescan (Linux `IN_Q_OVERFLOW`, an FSEvents history-dropped flag) means events were lost, not just
    /// coalesced, so the lost batch could have included a directory or submodule creation the watch set
    /// never registered a descriptor for; `handleFileSystemEvent` must reinstall (a second factory
    /// invocation), not just mark everything touched, to close that gap.
    @Test func aRescanEventReinstallsTheWatchAndMarksAllTouchedRegardlessOfPath() async throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        final class Counter: @unchecked Sendable { var value = 0 }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let factoryInvocations = Counter()
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                factoryInvocations.value += 1
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class LastFiring: @unchecked Sendable {
            private let lock = NSLock()
            private var touched: WorkspaceWatch.Touched?
            func record(_ value: WorkspaceWatch.Touched) {
                lock.lock()
                touched = value
                lock.unlock()
            }
            var value: WorkspaceWatch.Touched? {
                lock.lock()
                defer { lock.unlock() }
                return touched
            }
        }
        let lastFiring = LastFiring()
        let (token, _) = watch.subscribe { lastFiring.record($0) }
        defer { watch.unsubscribe(token) }
        #expect(factoryInvocations.value == 1)

        // An overflow/rescan carries no meaningful path list; the source can be anything, including an
        // empty list, since `mustRescan` alone decides.
        box.watcher?.onChange([], true)

        await waitUntil { factoryInvocations.value == 2 }
        #expect(factoryInvocations.value == 2, "a rescan must reinstall the watch, not just mark everything touched")
        await waitUntil { lastFiring.value != nil }
        #expect(lastFiring.value?.all == true)
    }

    /// A non-git workspace root (a plain project directory, no `.git` at all) must still get a working
    /// watch: `discoverRepositoryMap` treats it as one ungated repository-map entry instead of failing the
    /// whole install on the `git rev-parse` a real repository's discovery would run.
    @Test func subscribeReportsNoErrorForANonGitWorkspaceAndAnEventUnderItFiresWithTheRootTouched() async throws {
        let root = try makeNonGitWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class LastFiring: @unchecked Sendable {
            private let lock = NSLock()
            private var touched: WorkspaceWatch.Touched?
            func record(_ value: WorkspaceWatch.Touched) {
                lock.lock()
                touched = value
                lock.unlock()
            }
            var value: WorkspaceWatch.Touched? {
                lock.lock()
                defer { lock.unlock() }
                return touched
            }
        }
        let lastFiring = LastFiring()
        let (token, error) = watch.subscribe { lastFiring.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }

        let newFile = root.appendingPathComponent("untracked.txt").path
        box.watcher?.onChange([newFile], false)

        await waitUntil { lastFiring.value != nil }
        #expect(lastFiring.value?.directories == [root.path])
        #expect(lastFiring.value?.all == false)
    }

    /// A subscribed non-git workspace running `git init` must be noticed and re-mapped: the non-git
    /// repository-map entry `isRepositoryMapInvalidatingPath` starts from has a nil `gitDir`/`commonDir`,
    /// so checking only those (as the `.gitmodules`/`config` cases do) would never catch this; it must also
    /// compare against `<workingDir>/.git` directly for every mapped repository.
    @Test func runningGitInitOnASubscribedNonGitWorkspaceReinstallsAsAGitRepository() async throws {
        let root = try makeNonGitWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        final class Counter: @unchecked Sendable { var value = 0 }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let factoryInvocations = Counter()
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                factoryInvocations.value += 1
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class Firings: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [WorkspaceWatch.Touched] = []
            func record(_ touched: WorkspaceWatch.Touched) {
                lock.lock()
                recorded.append(touched)
                lock.unlock()
            }
            var all: [WorkspaceWatch.Touched] {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }
        }
        let firings = Firings()
        let (token, error) = watch.subscribe { firings.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }
        #expect(factoryInvocations.value == 1)

        try runGit(["init", "--initial-branch", "main"], cwd: root.path)
        box.watcher?.onChange([root.appendingPathComponent(".git").path], false)

        await waitUntil { factoryInvocations.value == 2 }
        #expect(factoryInvocations.value == 2, "a `git init` on the workspace root must reinstall the watch so the git layout is discovered")
        await waitUntil { firings.all.contains(where: { $0.all }) }
        #expect(firings.all.contains(where: { $0.all }), "the recompute after discovering the git layout must be marked full")

        let firingsBeforeObjectWrite = firings.all.count
        box.watcher?.onChange([root.appendingPathComponent(".git/objects/ab/cdef").path], false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(
            firings.all.count == firingsBeforeObjectWrite,
            "an object write is dropped by the git-dir allowlist now that the root is a git repository")
    }

    /// Product requirement: `FileManager.default.temporaryDirectory` (what both fixtures above build under)
    /// is itself a symlink on macOS (`/var/folders/...` resolves to `/private/var/folders/...`), and FSEvents
    /// reports every path in resolved form, not the form a caller's `workspaceRoot` was given in. A watch
    /// whose install and event matching stayed in the given (symlinked) form would silently drop every
    /// real-world event, since none of them would ever prefix-match `workspaceRoot` as given. This fires an
    /// event using the resolved path (standing in for what FSEvents/inotify actually report) and asserts the
    /// handler still receives `root.path`, the given form, matching what `RepositoryTouchedSet` and the
    /// contribution cache are keyed by.
    @Test func aResolvedSymlinkPathEventIsReportedBackInTheGivenWorkspaceRootForm() async throws {
        let realRoot = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: realRoot) }
        // The watch is handed a symlink to the repository, the shape a workspace recorded under a
        // symlinked directory (macOS's own `/var` and `/tmp` included) has. FSEvents and inotify report
        // the resolved spelling, so the test fires events in that form and expects the given one back.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-workspace-watch-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: realRoot)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolvedPointer = try #require(realpath(root.path, nil))
        let resolvedRoot = URL(fileURLWithPath: String(cString: resolvedPointer))
        free(resolvedPointer)
        #expect(resolvedRoot.path != root.path)

        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class LastFiring: @unchecked Sendable {
            private let lock = NSLock()
            private var touched: WorkspaceWatch.Touched?
            func record(_ value: WorkspaceWatch.Touched) {
                lock.lock()
                touched = value
                lock.unlock()
            }
            var value: WorkspaceWatch.Touched? {
                lock.lock()
                defer { lock.unlock() }
                return touched
            }
        }
        let lastFiring = LastFiring()
        let (token, error) = watch.subscribe { lastFiring.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }

        // The paths handed to the watcher factory are the ones actually installed, so they must be in
        // resolved form (matching what FSEvents/inotify would report), not the given, symlinked form.
        let installedPaths = box.watcher?.paths ?? []
        #expect(installedPaths.contains(resolvedRoot.path))
        #expect(!installedPaths.contains(root.path))

        let resolvedReadme = resolvedRoot.appendingPathComponent("README.md").path
        box.watcher?.onChange([resolvedReadme], false)

        await waitUntil { lastFiring.value != nil }
        #expect(lastFiring.value?.directories == [root.path])
        #expect(lastFiring.value?.all == false)
    }

    /// Product requirement: a directory created after install is classified against the repository's
    /// ignore rules before its own creation event (and every write that follows inside it) reaches
    /// acceptance, on every platform, not just Linux. Without this, `build/` (committed to `.gitignore`
    /// here) would never be added to `ignoreSets` since nothing else refreshes it, and every event under
    /// it would keep re-arming the debounce forever.
    @Test func aNewlyCreatedIgnoredDirectoryProducesNoFiringForItsCreationOrForFilesWrittenInsideIt() async throws {
        let root = try makeWorkspaceRepositoryIgnoringBuildDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.05, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class Firings: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [WorkspaceWatch.Touched] = []
            func record(_ touched: WorkspaceWatch.Touched) {
                lock.lock()
                recorded.append(touched)
                lock.unlock()
            }
            var all: [WorkspaceWatch.Touched] {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }
        }
        let firings = Firings()
        let (token, error) = watch.subscribe { firings.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }

        let buildDir = root.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        box.watcher?.onChange([buildDir.path], false)
        // No predicate to wait on here: the whole point is that nothing ever fires, so this waits out
        // several debounce windows and then asserts the negative.
        try await Task.sleep(for: .milliseconds(250))
        #expect(firings.all.isEmpty)

        let objectFile = buildDir.appendingPathComponent("out.o")
        try "object".write(to: objectFile, atomically: true, encoding: .utf8)
        box.watcher?.onChange([objectFile.path], false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(firings.all.isEmpty)

        let readme = root.appendingPathComponent("README.md").path
        box.watcher?.onChange([readme], false)
        await waitUntil { !firings.all.isEmpty }
        #expect(firings.all.count == 1)
        #expect(firings.all.first?.directories == [root.path])
    }

    /// Sibling of the ignored-directory test above: a directory created after install that is NOT covered
    /// by any ignore rule must still be classified (an ignore-listing spawn answering "not ignored") and
    /// then accepted normally, proving classification does not accidentally suppress a legitimate event.
    @Test func aNewlyCreatedNonIgnoredDirectoryStillFiresWithTheRootTouched() async throws {
        let root = try makeWorkspaceRepositoryIgnoringBuildDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class LastFiring: @unchecked Sendable {
            private let lock = NSLock()
            private var touched: WorkspaceWatch.Touched?
            func record(_ value: WorkspaceWatch.Touched) {
                lock.lock()
                touched = value
                lock.unlock()
            }
            var value: WorkspaceWatch.Touched? {
                lock.lock()
                defer { lock.unlock() }
                return touched
            }
        }
        let lastFiring = LastFiring()
        let (token, error) = watch.subscribe { lastFiring.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }

        let srcDir = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        box.watcher?.onChange([srcDir.path], false)

        await waitUntil { lastFiring.value != nil }
        #expect(lastFiring.value?.directories == [root.path])
        #expect(lastFiring.value?.all == false)
    }

    /// Sibling of both tests above for a non-git workspace: with no repository to check against, a newly
    /// created directory has nothing to be ignored by, so its creation event fires like any other.
    @Test func aNewlyCreatedDirectoryInANonGitWorkspaceFiresWithTheRootTouched() async throws {
        let root = try makeNonGitWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class LastFiring: @unchecked Sendable {
            private let lock = NSLock()
            private var touched: WorkspaceWatch.Touched?
            func record(_ value: WorkspaceWatch.Touched) {
                lock.lock()
                touched = value
                lock.unlock()
            }
            var value: WorkspaceWatch.Touched? {
                lock.lock()
                defer { lock.unlock() }
                return touched
            }
        }
        let lastFiring = LastFiring()
        let (token, error) = watch.subscribe { lastFiring.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }

        let buildDir = root.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        box.watcher?.onChange([buildDir.path], false)

        await waitUntil { lastFiring.value != nil }
        #expect(lastFiring.value?.directories == [root.path])
        #expect(lastFiring.value?.all == false)
    }

    /// A submodule's tree must never be registered under its parent's
    /// ignore rules before the submodule's own walk (with its own ignore set) has a chance to prune it;
    /// without pruning every descendant repository root, `linuxWatchPaths` would add `sub/out` from the
    /// superproject's walk (using the superproject's own, unrelated ignore set) before the submodule's own
    /// `.gitignore` is ever consulted. `linuxWatchPaths`/`enumerateDirectories` are a pure function of the
    /// map plus a filesystem fixture (not gated behind `#if os(Linux)`), so this needs no real inotify
    /// backend and runs on every platform.
    @Test func linuxWatchPathsPrunesADescendantRepositoryRootsTreeFromItsAncestorsWalk() throws {
        let base = resolvedTemporaryDirectory().appendingPathComponent(
            "spaces-workspace-watch-linux-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sub = base.appendingPathComponent("sub", isDirectory: true)
        let out = sub.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let rootEntry = WorkspaceWatch.RepositoryMapEntry(workingDir: base.path, gitDir: nil, commonDir: nil, ancestorWorkingDirs: [], depth: 0)
        let subEntry = WorkspaceWatch.RepositoryMapEntry(
            workingDir: sub.path, gitDir: nil, commonDir: nil, ancestorWorkingDirs: [base.path], depth: 1)

        let paths = WorkspaceWatch.linuxWatchPaths(for: [rootEntry, subEntry], ignoreSets: [base.path: [], sub.path: [out.path]])

        #expect(!paths.contains(out.path))
        #expect(paths.contains(sub.path))
        #expect(paths.contains(base.path))
    }

    /// A linked worktree's repo-level exclude file lives at
    /// `<commonDir>/info/exclude`, not `<gitDir>/info/exclude` (a worktree's own git dir has no
    /// `info/exclude` of its own). Writing it must both be accepted as a legitimate event in its own right
    /// (pinned separately, at the pure-logic level, in `SpacesDeviceWorkspaceWatchEventAcceptanceTests`) and
    /// refresh the ignore set, so a directory it newly ignores stops firing afterward.
    @Test func writingTheCommonDirInfoExcludeOfALinkedWorktreeRefreshesTheIgnoreSetAndSuppressesANewlyIgnoredDirectory() async throws {
        let (_, worktree, commonDir) = try makeLinkedWorktreeRepository()
        defer { try? FileManager.default.removeItem(at: worktree) }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: worktree.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class Firings: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [WorkspaceWatch.Touched] = []
            func record(_ touched: WorkspaceWatch.Touched) {
                lock.lock()
                recorded.append(touched)
                lock.unlock()
            }
            var all: [WorkspaceWatch.Touched] {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }
        }
        let firings = Firings()
        let (token, error) = watch.subscribe { firings.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }

        // Not yet ignored: this creation must fire normally.
        let buildDir = worktree.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        box.watcher?.onChange([buildDir.path], false)
        await waitUntil { !firings.all.isEmpty }
        #expect(firings.all.count == 1)

        // Rewriting the shared commonDir exclude file to cover `build/` must itself be accepted (the
        // acceptance-layer half of the fix) and refresh the ignore set for the very same event.
        let excludeFile = commonDir.appendingPathComponent("info").appendingPathComponent("exclude")
        try "build/\n".write(to: excludeFile, atomically: true, encoding: .utf8)
        box.watcher?.onChange([excludeFile.path], false)
        await waitUntil { firings.all.count >= 2 }
        #expect(firings.all.count == 2)

        // Now that `build/` is ignored via the refreshed commonDir exclude file, a write inside it must
        // produce no further firing.
        let newFile = buildDir.appendingPathComponent("new.txt")
        try "x".write(to: newFile, atomically: true, encoding: .utf8)
        box.watcher?.onChange([newFile.path], false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(firings.all.count == 2)
    }

    /// An external `core.excludesFile` is honored by `--exclude-standard` (and so this ignore
    /// listing) exactly like `.gitignore` and the repo-level exclude file, but it is a `config`/
    /// `config.worktree` write that actually sets or changes it. `refreshIgnoreSetIfGitignoreChanged` must
    /// treat `<gitDir>/config` as an invalidator the same way it already treats `info/exclude` above.
    /// `git config core.excludesFile <path>` here is a plain LOCAL (repo-scoped) config write, landing in
    /// `.git/config`, not `--global`: the point under test is the `config` file itself, not which scope
    /// the setting lives at, and a local write keeps this fixture fully isolated from the host's own
    /// global gitignore.
    @Test func writingTheGitDirConfigAfterSettingCoreExcludesFileRefreshesTheIgnoreSetAndSuppressesANewlyIgnoredDirectory() async throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class Firings: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [WorkspaceWatch.Touched] = []
            func record(_ touched: WorkspaceWatch.Touched) {
                lock.lock()
                recorded.append(touched)
                lock.unlock()
            }
            var all: [WorkspaceWatch.Touched] {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }
        }
        let firings = Firings()
        let (token, error) = watch.subscribe { firings.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }

        // Not yet ignored: this creation must fire normally.
        let buildDir = root.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        box.watcher?.onChange([buildDir.path], false)
        await waitUntil { !firings.all.isEmpty }
        #expect(firings.all.count == 1)

        // A gitignore-format file, external to the repository, that covers `build/`, wired in via
        // `core.excludesFile`.
        let globalExcludes = resolvedTemporaryDirectory().appendingPathComponent(
            "spaces-workspace-watch-global-excludes-\(UUID().uuidString)")
        try "build/\n".write(to: globalExcludes, atomically: true, encoding: .utf8)
        try runGit(["config", "core.excludesFile", globalExcludes.path], cwd: root.path)

        // Reporting the `config` write itself must be accepted (see `gitDirAllowedTopLevelNames`) and
        // refresh the ignore set for the very same event, exactly like the info/exclude case above.
        let configFile = root.appendingPathComponent(".git").appendingPathComponent("config")
        box.watcher?.onChange([configFile.path], false)
        await waitUntil { firings.all.count >= 2 }
        #expect(firings.all.count == 2)

        // Now that `build/` is ignored via `core.excludesFile`, a write inside it must produce no further
        // firing.
        let newFile = buildDir.appendingPathComponent("new.txt")
        try "x".write(to: newFile, atomically: true, encoding: .utf8)
        box.watcher?.onChange([newFile.path], false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(firings.all.count == 2)
    }

    /// `isUnclassifiedNewDirectory` and `classifyNewDirectories` must resolve a candidate's owning
    /// repository by the DEEPEST working-dir match, matching
    /// `WorkspaceWatchEventAcceptance.deepestWorkingDirMatch`, not a plain `first(where:)` over the
    /// repository map: a shallower match would classify a directory created inside an initialized
    /// submodule against the superproject, whose `ls-files` never lists a path under a gitlink, so it
    /// would never land in the submodule's own ignore set and every event under it would keep
    /// recomputing.
    @Test func aDirectoryCreatedInsideASubmoduleIsClassifiedAgainstTheSubmodulesOwnIgnoreRules() async throws {
        let (container, superRoot, submoduleWorkingDir) = try makeWorkspaceRepositoryWithSubmoduleIgnoringBuildDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: superRoot.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.05, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class Firings: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [WorkspaceWatch.Touched] = []
            func record(_ touched: WorkspaceWatch.Touched) {
                lock.lock()
                recorded.append(touched)
                lock.unlock()
            }
            var all: [WorkspaceWatch.Touched] {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }
        }
        let firings = Firings()
        let (token, error) = watch.subscribe { firings.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }

        let buildDir = submoduleWorkingDir.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        box.watcher?.onChange([buildDir.path], false)
        // Classification (against the submodule's own ignore rules, once the fix resolves the deepest
        // match) runs before acceptance judges this same event, so the creation may or may not fire; only
        // the count is pinned here, before the write below.
        try await Task.sleep(for: .milliseconds(250))
        let firingsAfterCreate = firings.all.count

        let probe = buildDir.appendingPathComponent("x")
        try "x".write(to: probe, atomically: true, encoding: .utf8)
        box.watcher?.onChange([probe.path], false)
        try await Task.sleep(for: .milliseconds(250))
        #expect(
            firings.all.count == firingsAfterCreate,
            "a write inside a directory the submodule's own .gitignore covers must not fire once classified against the submodule's own ignore rules"
        )
    }

    /// A submodule added or initialized while a subscription is live must end up mapped as its own
    /// repository, not left folded into the superproject's coverage until some unrelated event happens to
    /// trigger the next reinstall: `.gitmodules` (rewritten by `git submodule add`) and a repository's
    /// `config` (rewritten by `git submodule update --init` for an already-recorded entry) both invalidate
    /// the map via `isRepositoryMapInvalidatingPath`, and the recompute that follows must be a full one,
    /// since the touched set collected before the reinstall was computed against the stale map.
    @Test func aSubmoduleAddedWhileSubscribedIsMappedAsItsOwnRepositoryAfterAGitmodulesEvent() async throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let submoduleSource = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: submoduleSource) }

        final class Counter: @unchecked Sendable { var value = 0 }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let factoryInvocations = Counter()
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                factoryInvocations.value += 1
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class Firings: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [WorkspaceWatch.Touched] = []
            func record(_ touched: WorkspaceWatch.Touched) {
                lock.lock()
                recorded.append(touched)
                lock.unlock()
            }
            var all: [WorkspaceWatch.Touched] {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }
        }
        let firings = Firings()
        let (token, error) = watch.subscribe { firings.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }
        #expect(factoryInvocations.value == 1)

        try runGit(["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleSource.path, "sub"], cwd: root.path)
        box.watcher?.onChange([root.appendingPathComponent(".gitmodules").path], false)

        await waitUntil { factoryInvocations.value == 2 }
        #expect(factoryInvocations.value == 2, "a `.gitmodules` write must reinstall the watch so the new submodule enters the map")
        await waitUntil { firings.all.contains(where: { $0.all }) }
        #expect(
            firings.all.contains(where: { $0.all }),
            "the recompute after a map rebuild must be marked full: the old touched set was collected against the stale map")

        let subWorkingDir = root.appendingPathComponent("sub").path
        let subReadme = root.appendingPathComponent("sub/README.md").path
        try "changed".write(toFile: subReadme, atomically: true, encoding: .utf8)
        box.watcher?.onChange([subReadme], false)

        await waitUntil { firings.all.contains(where: { $0.directories.contains(subWorkingDir) }) }
        #expect(
            firings.all.contains(where: { $0.directories.contains(subWorkingDir) }),
            "the submodule must now be its own repository in the map, not folded into the superproject's working directory")

        // `config` invalidates the map the same way: `git submodule update --init` for an existing entry
        // writes `submodule.<name>.url` into it without ever touching `.gitmodules`.
        try runGit(["config", "submodule.sub.url", "x"], cwd: root.path)
        box.watcher?.onChange([root.appendingPathComponent(".git/config").path], false)
        await waitUntil { factoryInvocations.value == 3 }
        #expect(factoryInvocations.value == 3, "a repository `config` write must also reinstall the watch")
    }

    /// `git submodule update --init` on an already-tracked but NOT YET initialized gitlink writes the
    /// superproject's `config` (`submodule.sub.url`) BEFORE the submodule's own checkout directory and its
    /// `.git` even exist, so a rebuild triggered by that earlier `config` write still finds an uninitialized
    /// checkout: `sub` never becomes its own mapped repository until its OWN `<root>/sub/.git` is created a
    /// moment later. `isRepositoryMapInvalidatingPath`'s old `<workingDir>/.git` check only ever matched a
    /// `.git` directly under an ALREADY-mapped repository's own working directory, never one nested another
    /// level below it (`<root>/sub/.git`, under the SUPERPROJECT's mapped working directory, not `sub`'s own,
    /// since `sub` is not mapped yet), so this reports ONLY the `sub/.git` creation, deliberately never the
    /// earlier `config` write, to isolate the generalized any-depth `.git` check from the already-covered
    /// `config` trigger the test above exercises.
    @Test func aGitlinkInitializedAfterDeinitIsMappedAsItsOwnRepositoryOnceItsOwnGitAppears() async throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let submoduleSource = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: submoduleSource) }

        try runGit(["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleSource.path, "sub"], cwd: root.path)
        try runGit(
            ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add sub"], cwd: root.path)
        // Deinitializing empties `sub`'s working tree (no more `sub/.git`) and unsets its `config` entry
        // while leaving `.gitmodules` and the gitlink itself intact, matching a superproject cloned without
        // `--recurse-submodules`: the gitlink is already tracked, but its checkout is not there yet.
        try runGit(["submodule", "deinit", "-f", "sub"], cwd: root.path)

        final class Counter: @unchecked Sendable { var value = 0 }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let factoryInvocations = Counter()
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                factoryInvocations.value += 1
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class Firings: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [WorkspaceWatch.Touched] = []
            func record(_ touched: WorkspaceWatch.Touched) {
                lock.lock()
                recorded.append(touched)
                lock.unlock()
            }
            var all: [WorkspaceWatch.Touched] {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }
        }
        let firings = Firings()
        let (token, error) = watch.subscribe { firings.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }
        #expect(factoryInvocations.value == 1)

        try runGit(["-c", "protocol.file.allow=always", "submodule", "update", "--init", "sub"], cwd: root.path)
        box.watcher?.onChange([root.appendingPathComponent("sub/.git").path], false)

        await waitUntil { factoryInvocations.value == 2 }
        #expect(
            factoryInvocations.value == 2,
            "the newly initialized gitlink's own `.git` must reinstall the watch even though only the superproject was mapped when it appeared")
        await waitUntil { firings.all.contains(where: { $0.all }) }
        #expect(
            firings.all.contains(where: { $0.all }),
            "the recompute after a map rebuild must be marked full: the old touched set was collected against the stale map")

        let subWorkingDir = root.appendingPathComponent("sub").path
        let subReadme = root.appendingPathComponent("sub/README.md").path
        try "changed".write(toFile: subReadme, atomically: true, encoding: .utf8)
        box.watcher?.onChange([subReadme], false)

        await waitUntil { firings.all.contains(where: { $0.directories.contains(subWorkingDir) }) }
        #expect(
            firings.all.contains(where: { $0.directories.contains(subWorkingDir) }),
            "the submodule must now be its own repository in the map, not folded into the superproject's working directory")
    }

    /// A path naming a repository's git dir ROOT itself (`.git` deleted or renamed) derives an empty
    /// relative name in `WorkspaceWatchEventAcceptance.nameIsAcceptedUnderGitDir` and so is rejected as an
    /// ordinary event, but `isRepositoryMapInvalidatingPath` must still trigger a rebuild for it: without
    /// that, a repository that drops out of git entirely would leave `WorkspaceWatch` stuck treating the
    /// workspace as still git-backed forever, matching against a git dir that no longer exists.
    @Test func removingTheGitDirectoryReinstallsAsANonGitWorkspaceAndTouchesTheRoot() async throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        final class Counter: @unchecked Sendable { var value = 0 }
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let factoryInvocations = Counter()
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                factoryInvocations.value += 1
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class Firings: @unchecked Sendable {
            private let lock = NSLock()
            private var recorded: [WorkspaceWatch.Touched] = []
            func record(_ touched: WorkspaceWatch.Touched) {
                lock.lock()
                recorded.append(touched)
                lock.unlock()
            }
            var all: [WorkspaceWatch.Touched] {
                lock.lock()
                defer { lock.unlock() }
                return recorded
            }
        }
        let firings = Firings()
        let (token, error) = watch.subscribe { firings.record($0) }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }
        #expect(factoryInvocations.value == 1)

        let gitDir = root.appendingPathComponent(".git").path
        try FileManager.default.removeItem(atPath: gitDir)
        box.watcher?.onChange([gitDir], false)

        await waitUntil { factoryInvocations.value == 2 }
        #expect(factoryInvocations.value == 2, "the git dir itself being removed must reinstall the watch")
        await waitUntil { firings.all.contains(where: { $0.all }) }
        #expect(firings.all.contains(where: { $0.all }), "the recompute after losing the git dir must be marked full")

        let newFile = root.appendingPathComponent("untracked.txt").path
        try "x".write(toFile: newFile, atomically: true, encoding: .utf8)
        box.watcher?.onChange([newFile], false)

        await waitUntil { firings.all.contains(where: { $0.directories == [root.path] }) }
        #expect(
            firings.all.contains(where: { $0.directories == [root.path] }),
            "the workspace must now be mapped as a single non-git root")
    }

    /// `classifyIgnored` must treat a candidate as ignored when it EQUALS
    /// or lies under a reported entry, not just on an exact match, since `ls-files --ignored --directory`
    /// reports only the shallowest ignored ancestor (`node_modules/`, never `node_modules/x`). A pure test
    /// of the classification helper itself, real git repository fixture, no watcher needed.
    @Test func classifyIgnoredTreatsADeeperCandidateAsIgnoredWhenItsAncestorIsTheReportedEntry() throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try "node_modules/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], cwd: root.path)
        try runGit(
            ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "ignore node_modules"], cwd: root.path)

        let nodeModules = root.appendingPathComponent("node_modules", isDirectory: true)
        let nodeModulesX = nodeModules.appendingPathComponent("x", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModulesX, withIntermediateDirectories: true)
        let srcNew = root.appendingPathComponent("src/new", isDirectory: true)
        try FileManager.default.createDirectory(at: srcNew, withIntermediateDirectories: true)

        let classified = try WorkspaceWatch.classifyIgnored(
            [nodeModules.path, nodeModulesX.path, srcNew.path], workingDir: root.path, gitClient: RemoteWorkspaceGitClient())

        #expect(Set(classified.ignored) == Set([nodeModules.path, nodeModulesX.path]))
        #expect(classified.nonIgnored == [srcNew.path])
    }

    /// `<commonDir>/info` (home to `info/exclude`) sits outside `refs/`,
    /// so watching `commonDir` alone never covers it on Linux, where inotify is not recursive. Portable:
    /// `linuxWatchPaths` is a pure function of the map plus a filesystem fixture, exercised directly here
    /// without needing a real Linux inotify backend (`git init` already creates `.git/info/exclude`, so
    /// this fixture needs no extra setup).
    @Test func linuxWatchPathsIncludesCommonDirInfo() throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git")
        let entry = WorkspaceWatch.RepositoryMapEntry(
            workingDir: root.path, gitDir: gitDir.path, commonDir: gitDir.path, ancestorWorkingDirs: [], depth: 0)

        let paths = WorkspaceWatch.linuxWatchPaths(for: [entry], ignoreSets: [root.path: []])

        #expect(paths.contains(gitDir.appendingPathComponent("info").path))
    }

    /// `--ref-format=reftable` needs git >= 2.44 (stabilized as a supported format in 2.45); an older
    /// toolchain rejects the flag outright, so this parses `git --version` and lets the caller skip
    /// cleanly rather than failing the suite on an old git.
    private func gitSupportsRefFormatFlag() throws -> Bool {
        let output = try runGit(["--version"], cwd: FileManager.default.temporaryDirectory.path)
        // "git version 2.45.1" (possibly with a vendor suffix, e.g. "2.45.1.windows.1").
        guard let versionToken = output.split(separator: " ").dropFirst(2).first else { return false }
        let components = versionToken.split(separator: ".").prefix(2).compactMap { Int($0) }
        guard components.count == 2 else { return false }
        return components[0] > 2 || (components[0] == 2 && components[1] >= 45)
    }

    /// A repository using the reftable ref storage format rewrites
    /// `<commonDir>/reftable/tables.list` on every ref update instead of touching anything under `refs/`,
    /// so `linuxWatchPaths` must add `<commonDir>/reftable` too. Skips cleanly on a git toolchain that
    /// predates `--ref-format=reftable`.
    @Test func linuxWatchPathsIncludesCommonDirReftableWhenTheRepositoryUsesTheReftableBackend() throws {
        guard try gitSupportsRefFormatFlag() else { return }
        let root = resolvedTemporaryDirectory().appendingPathComponent(
            "spaces-workspace-watch-reftable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "--initial-branch", "main", "--ref-format=reftable"], cwd: root.path)
        try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], cwd: root.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: root.path)

        let gitDir = root.appendingPathComponent(".git")
        let entry = WorkspaceWatch.RepositoryMapEntry(
            workingDir: root.path, gitDir: gitDir.path, commonDir: gitDir.path, ancestorWorkingDirs: [], depth: 0)

        let paths = WorkspaceWatch.linuxWatchPaths(for: [entry], ignoreSets: [root.path: []])

        #expect(paths.contains(gitDir.appendingPathComponent("reftable").path))
    }

    /// A pre-existing directory SYMLINK inside a repository's working directory must never be added to the
    /// inotify watch set: `enumerateDirectories` resolves `.isDirectoryKey` through the symlink (`stat`
    /// semantics), so without an explicit `.isSymbolicLinkKey` check it would insert the symlink's own path
    /// (and, since the enumerator can also descend through it, potentially the target's whole subtree too),
    /// which can watch a directory entirely outside the workspace. Portable: `linuxWatchPaths` is a pure
    /// function of the map plus a filesystem fixture, exercised directly here without a real inotify
    /// backend.
    @Test func linuxWatchPathsExcludesAPreexistingDirectorySymlink() throws {
        let base = resolvedTemporaryDirectory().appendingPathComponent(
            "spaces-workspace-watch-linux-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let outside = resolvedTemporaryDirectory().appendingPathComponent(
            "spaces-workspace-watch-linux-symlink-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let entry = WorkspaceWatch.RepositoryMapEntry(workingDir: base.path, gitDir: nil, commonDir: nil, ancestorWorkingDirs: [], depth: 0)
        let paths = WorkspaceWatch.linuxWatchPaths(for: [entry], ignoreSets: [base.path: []])

        #expect(!paths.contains(link.path), "a directory symlink must never be added to the watch set")
        #expect(paths.contains(base.path))
    }

    /// Writes a git shim script that execs the real `git` for every invocation except a failing `ls-files`
    /// call, letting the whole-repository listing at install time and every other git call succeed
    /// normally. Two independent gating modes, chosen by whether `markerPath` is given:
    /// - Empty `markerPath` (the default): fails unconditionally on the first `ls-files` call that carries
    ///   pathspecs after `--` (the call `ignoredDirectories(limitedTo:)` makes from `classifyNewDirectories`
    ///   classifying a freshly created directory); a plain whole-repository listing (no pathspecs) always
    ///   succeeds, which is what lets install itself complete.
    /// - Non-empty `markerPath`: fails every `ls-files` call, pathspecs or not, once a file exists at that
    ///   path, and succeeds otherwise. A `.gitignore`-change refresh lists the whole repository again (no
    ///   pathspecs, same as install), so it needs this unconditional-on-`ls-files` mode rather than the
    ///   pathspec gate; a test using it lets install complete, then creates the marker to fail exactly the
    ///   later refresh call it wants to exercise. Passing a `markerPath` whose file is never created is also
    ///   how a test gets a shim that never fails at all (the marker check always misses), while still
    ///   layering `logPath` on top.
    /// - `logPath`, independent of either gating mode: when non-empty, every invocation appends its
    ///   subcommand (`$3`, e.g. "ls-files", "rev-parse") as one line, so a test can count real `ls-files`
    ///   spawns (a classification/refresh cost this file works hard to avoid repeating) without the shim
    ///   itself needing to fail anything.
    private func makeLsFilesPathspecFailureShim(root: URL, markerPath: String = "", logPath: String = "") throws -> RemoteWorkspaceGitClient {
        let scriptURL = root.appendingPathComponent("git-ls-files-shim.sh")
        let script = """
            #!/bin/sh
            MARKER_PATH="\(markerPath)"
            LOG_PATH="\(logPath)"
            if [ -n "$LOG_PATH" ]; then
                printf '%s\\n' "$3" >> "$LOG_PATH"
            fi
            if [ "$3" = "ls-files" ]; then
                if [ -n "$MARKER_PATH" ]; then
                    if [ -e "$MARKER_PATH" ]; then
                        exit 128
                    fi
                else
                    found_separator=0
                    has_pathspec=0
                    for arg in "$@"; do
                        if [ "$found_separator" = "1" ]; then
                            has_pathspec=1
                            break
                        fi
                        if [ "$arg" = "--" ]; then
                            found_separator=1
                        fi
                    done
                    if [ "$has_pathspec" = "1" ]; then
                        exit 128
                    fi
                fi
            fi
            exec git "$@"
            """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return RemoteWorkspaceGitClient(gitExecutable: scriptURL.path)
    }

    /// A classification-spawn failure (E2BIG despite the chunking in
    /// `classifyIgnored`, or git failing outright) must be treated exactly like an install failure, not
    /// silently swallowed. `RemoteWorkspaceGitClient(gitExecutable:)` is the established seam
    /// (`WorkspaceGitServerTests.swift`'s stub-script substitutions) for injecting a git failure: this shim
    /// execs the real git for every invocation EXCEPT an `ls-files` call that carries pathspecs after `--`
    /// (the classification spawn `ignoredDirectories(limitedTo:)` makes), which it fails outright, letting
    /// the whole-repository listing at install time (no pathspecs) and every other git call succeed
    /// normally.
    @Test func aClassificationSpawnFailureIsTreatedAsAWatcherFailureAndSurfacesThroughCurrentStartError() async throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let gitClient = try makeLsFilesPathspecFailureShim(root: root)
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: gitClient, debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class LastFiring: @unchecked Sendable {
            private let lock = NSLock()
            private var touched: WorkspaceWatch.Touched?
            func record(_ value: WorkspaceWatch.Touched) {
                lock.lock()
                touched = value
                lock.unlock()
            }
            var value: WorkspaceWatch.Touched? {
                lock.lock()
                defer { lock.unlock() }
                return touched
            }
        }
        let lastFiring = LastFiring()
        let (token, error) = watch.subscribe { lastFiring.record($0) }
        #expect(error == nil, "install itself must succeed: the shim only fails a classification spawn, not the whole-repo install listing")
        defer { watch.unsubscribe(token) }

        let newDir = root.appendingPathComponent("new-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        box.watcher?.onChange([newDir.path], false)

        await waitUntil { lastFiring.value != nil }
        guard let touched = lastFiring.value else {
            Issue.record("no firing after the classification spawn failed")
            return
        }
        #expect(touched.all == true, "a classification failure must force an all-touched rescan-style firing")
        #expect(watch.currentStartError() != nil, "a classification failure must surface through currentStartError, matching an install failure")
    }

    /// `refreshIgnoreSetIfGitignoreChanged` must not silently keep the
    /// previous ignore set when re-listing fails: on Linux, a rule that just stopped excluding a directory
    /// would then leave it unwatched forever with no signal anything went wrong. A refresh failure must
    /// surface exactly like a classification failure. The marker-gated shim mode lets install (and its own
    /// whole-repository listing) succeed first, then fails only the LATER refresh triggered by writing
    /// `.gitignore`.
    @Test func aGitignoreRefreshSpawnFailureIsTreatedAsAWatcherFailureAndSurfacesThroughCurrentStartError() async throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let markerPath = root.appendingPathComponent("fail-ls-files-marker").path
        let gitClient = try makeLsFilesPathspecFailureShim(root: root, markerPath: markerPath)
        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: gitClient, debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class LastFiring: @unchecked Sendable {
            private let lock = NSLock()
            private var touched: WorkspaceWatch.Touched?
            func record(_ value: WorkspaceWatch.Touched) {
                lock.lock()
                touched = value
                lock.unlock()
            }
            var value: WorkspaceWatch.Touched? {
                lock.lock()
                defer { lock.unlock() }
                return touched
            }
        }
        let lastFiring = LastFiring()
        let (token, error) = watch.subscribe { lastFiring.record($0) }
        #expect(error == nil, "install itself must succeed: the marker does not exist yet")
        defer { watch.unsubscribe(token) }

        // Only after the watch is already healthy does the shim start failing ls-files.
        try Data().write(to: URL(fileURLWithPath: markerPath))

        let gitignore = root.appendingPathComponent(".gitignore")
        try "build/\n".write(to: gitignore, atomically: true, encoding: .utf8)
        box.watcher?.onChange([gitignore.path], false)

        await waitUntil { lastFiring.value != nil }
        guard let touched = lastFiring.value else {
            Issue.record("no firing after the gitignore refresh spawn failed")
            return
        }
        #expect(touched.all == true, "a gitignore-refresh failure must force an all-touched rescan-style firing")
        #expect(
            watch.currentStartError() != nil,
            "a gitignore-refresh failure must surface through currentStartError, matching an install/classification failure")
    }

    /// FSEvents (and an ordinary `mkdir`-then-write sequence on Linux)
    /// reports a directory's path again on every later create/rename inside it, since an atomic save
    /// writes a temp file and renames it into place, both attributed to the containing directory. Without
    /// remembering an already-classified non-ignored directory, every such report would rerun `git
    /// ls-files` on it forever. The shim's `markerPath` names a file this test never creates, so it never
    /// fails anything; only `logPath` is exercised, to count real `ls-files` spawns.
    @Test func aClassifiedNonIgnoredDirectoryIsNotReclassifiedOnARepeatedEvent() async throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = root.appendingPathComponent("ls-files-invocations.log")
        try "".write(to: logURL, atomically: true, encoding: .utf8)
        let neverCreatedMarker = root.appendingPathComponent("never-created-marker").path
        let gitClient = try makeLsFilesPathspecFailureShim(root: root, markerPath: neverCreatedMarker, logPath: logURL.path)

        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: gitClient, debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class FiringCount: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        let firings = FiringCount()
        let (token, error) = watch.subscribe { _ in firings.increment() }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }

        func lsFilesSpawnCount() -> Int {
            let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            return contents.split(separator: "\n").filter { $0 == "ls-files" }.count
        }

        let newDir = root.appendingPathComponent("src/new", isDirectory: true)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        box.watcher?.onChange([newDir.path], false)

        await waitUntil { firings.value >= 1 }
        let spawnsAfterFirstClassification = lsFilesSpawnCount()
        #expect(spawnsAfterFirstClassification >= 1, "the first classification must spawn ls-files at least once")

        // Reporting the same directory again, and a file inside it, must not spend another spawn: `src/new`
        // is already known non-ignored.
        let fileInside = newDir.appendingPathComponent("file.txt")
        try "hello".write(to: fileInside, atomically: true, encoding: .utf8)
        box.watcher?.onChange([newDir.path, fileInside.path], false)

        await waitUntil { firings.value >= 2 }
        #expect(
            lsFilesSpawnCount() == spawnsAfterFirstClassification,
            "a repeated event under an already-classified directory must not reclassify it")
    }

    /// A directory SYMLINK reported by the watcher must never be classified (no `ls-files` spawn) or, on
    /// Linux, registered with the watcher's own inotify descriptor table: `pathIsDirectory` uses `lstat`,
    /// which reports `false` for a symlink even when its target is a directory, so
    /// `isUnclassifiedNewDirectory` rejects it before `classifyNewDirectories` (and, on Linux, `addPaths`)
    /// ever runs. Reuses the same `ls-files`-spawn-counting shim as the repeated-event test above. An
    /// ordinary FIRING still happens (the plain path itself is an accepted, ignore-set-independent event
    /// under the repository, unrelated to directory classification), which is what this waits on rather
    /// than an arbitrary sleep.
    @Test func aDirectorySymlinkIsNeverClassifiedOrRegisteredWithTheWatcher() async throws {
        let root = try makeWorkspaceRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = root.appendingPathComponent("ls-files-invocations.log")
        try "".write(to: logURL, atomically: true, encoding: .utf8)
        let neverCreatedMarker = root.appendingPathComponent("never-created-marker").path
        let gitClient = try makeLsFilesPathspecFailureShim(root: root, markerPath: neverCreatedMarker, logPath: logURL.path)

        final class WatcherBox: @unchecked Sendable { var watcher: FakeWatcher? }
        let box = WatcherBox()
        let watch = WorkspaceWatch(
            workspaceRoot: root.path, gitClient: gitClient, debounceInterval: 0.02, debounceCeiling: 1,
            watcherFactory: { paths, onChange in
                let watcher = FakeWatcher(paths: paths, onChange: onChange, startResults: [.success(())])
                box.watcher = watcher
                return watcher
            })

        final class FiringCount: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }
        let firings = FiringCount()
        let (token, error) = watch.subscribe { _ in firings.increment() }
        #expect(error == nil)
        defer { watch.unsubscribe(token) }

        func lsFilesSpawnCount(_ contents: String) -> Int {
            contents.split(separator: "\n").filter { $0 == "ls-files" }.count
        }
        // Install itself already spawns the whole-repository `ls-files` listing `attemptInstallLocked`
        // runs, so the assertion below must compare against the count already in the log right after
        // `subscribe`, not against zero.
        let before = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let spawnsBeforeTheSymlinkEvent = lsFilesSpawnCount(before)

        let outside = resolvedTemporaryDirectory().appendingPathComponent(
            "spaces-workspace-watch-symlink-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        box.watcher?.onChange([link.path], false)

        await waitUntil { firings.value >= 1 }
        let after = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        #expect(
            lsFilesSpawnCount(after) == spawnsBeforeTheSymlinkEvent,
            "a directory symlink must never trigger a classification spawn")
        #if os(Linux)
            #expect(
                box.watcher?.addedPaths.isEmpty == true,
                "a directory symlink must never be registered with the watcher's own inotify descriptor table")
        #endif
    }
}

/// Product requirement: `WatchError`'s own text names the syscall and `strerror`, but not the fix. An
/// `ENOSPC` inotify failure (the `fs.inotify.max_user_watches` limit) is the one case with an actual
/// remediation, so `WorkspaceWatch.annotatedErrorText` appends it; every other error text passes through
/// unchanged.
@Suite struct WorkspaceWatchAnnotatedErrorTextTests {
    @Test func anEnospcErrorTextGetsTheSysctlRemediationAppended() {
        let text = "inotify_add_watch(/workspace/build): No space left on device (ENOSPC)"
        #expect(WorkspaceWatch.annotatedErrorText(for: text) == text + " Raise fs.inotify.max_user_watches on the device.")
    }

    @Test func anyOtherErrorTextIsUnchanged() {
        let text = "inotify_add_watch(/workspace/build): Not a directory (ENOTDIR)"
        #expect(WorkspaceWatch.annotatedErrorText(for: text) == text)
    }
}
