// Real-backend coverage for `WorkspaceWatch` on Linux: an actual inotify-backed `FileSystemWatcher` (no
// injected fake), watching a real git repository, exercising the full install -> event -> debounce ->
// firing pipeline end to end. `SpacesDeviceWorkspaceWatchTests.swift` covers the same class's logic with a
// fake watcher and is macOS-only (not in this target's Linux source whitelist); this file is the Linux
// counterpart the plan's "Real backends" test line calls for.
//
// Swift Testing (not XCTest) on purpose: run_linux_tests.sh's lane uses the swift-testing async-main
// runner, since an async XCTest method deadlocks on Linux (corelibs-xctest never drains queued async work
// on its blocked main thread).
#if os(Linux)
    import Foundation
    import Testing
    import spacesruntimecore
    import workspacecore

    @testable import spacesdeviceapi

    /// `.serialized`: every test here calls `subscribe`, which blocks the calling cooperative-pool thread on
    /// `queue.sync` -> `attemptInstallLocked` -> `runBlocking` -> `semaphore.wait()` until `runBlocking`'s
    /// inner `Task` itself gets a pool thread to run the real inotify watcher's `start()` on. N tests
    /// running in parallel on an N-wide pool (the CI runner's CPU count, 4) all park in `subscribe` at once,
    /// leaving no thread to run any of their `runBlocking` tasks and deadlocking the whole process;
    /// serializing keeps at most one thread parked, matching `SpacesDeviceWorkspaceWatchTests.swift`'s fix.
    @Suite(.serialized) struct SpacesDeviceWorkspaceWatchLinuxTests {
        /// Container-local temporary directory, never the bind-mounted worktree: Docker Desktop's
        /// virtiofs/osxfs bind mount does not propagate host filesystem writes into the container as
        /// inotify events, so a test against the mounted repo would hang or silently miss changes
        /// depending on the host. `FileManager.default.temporaryDirectory` resolves to the container's own
        /// tmpfs, which does deliver inotify events.
        private func makeTempDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
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
            guard process.terminationStatus == 0 else {
                struct GitFixtureError: Error, CustomStringConvertible { let description: String }
                throw GitFixtureError(description: "git \(arguments.joined(separator: " ")) failed")
            }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }

        private func makeRepository() throws -> URL {
            let root = try makeTempDirectory()
            try runGit(["init", "--initial-branch", "main"], cwd: root.path)
            try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            try runGit(["add", "-A"], cwd: root.path)
            try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: root.path)
            return root
        }

        private func waitUntil(timeout: TimeInterval = 10, _ predicate: @escaping @Sendable () -> Bool) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }

        private final class LastTouched: @unchecked Sendable {
            private let lock = NSLock()
            private var value: WorkspaceWatch.Touched?
            private var firings = 0
            func record(_ touched: WorkspaceWatch.Touched) {
                lock.lock()
                value = touched
                firings += 1
                lock.unlock()
            }
            var current: WorkspaceWatch.Touched? {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return firings
            }
        }

        @Test func aRealInotifyWatchTouchesTheRepositoryWhenAFileChanges() async throws {
            let root = try makeRepository()
            defer { try? FileManager.default.removeItem(at: root) }
            let watch = WorkspaceWatch(workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.1, debounceCeiling: 1)

            let lastTouched = LastTouched()
            let (token, startError) = watch.subscribe { lastTouched.record($0) }
            defer { watch.unsubscribe(token) }
            #expect(startError == nil)

            try "edited".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

            await waitUntil { lastTouched.current != nil }
            guard let touched = lastTouched.current else {
                Issue.record("no touched-repository firing within the timeout")
                return
            }
            #expect(touched.directories.contains(root.path))
        }

        /// A directory created after install has no watch of its own until `WorkspaceWatch` registers one
        /// via `FileSystemWatcher.addPaths` (inotify is not recursive); a file written inside it shortly
        /// after creation must still be observed. This is the real-inotify counterpart of
        /// `SpacesDeviceWorkspaceWatchTests`' fake-watcher `addPaths` coverage.
        ///
        /// Not covered here: an actual `IN_Q_OVERFLOW` rescan. Provoking a real kernel inotify-queue
        /// overflow deterministically (flooding it faster than the daemon drains it) is not something this
        /// suite can reproduce reliably; the fake-watcher suite exercises `mustRescan` handling directly by
        /// firing it through the injected watcher instead.
        @Test func aFileInADirectoryCreatedAfterInstallIsStillObserved() async throws {
            let root = try makeRepository()
            defer { try? FileManager.default.removeItem(at: root) }
            let watch = WorkspaceWatch(workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.1, debounceCeiling: 1)

            let lastTouched = LastTouched()
            let (token, startError) = watch.subscribe { lastTouched.record($0) }
            defer { watch.unsubscribe(token) }
            #expect(startError == nil)

            let nested = root.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            // The directory's own creation is an accepted event on the root and fires by itself, so that
            // firing is waited out first; only a SECOND firing, after the write inside `nested`, proves
            // the new directory was registered with inotify (its parent's watch never reports events for
            // entries below a child directory). The extra sleep gives the registration (an ignore-listing
            // `git ls-files` spawn plus an `addPaths` call) time to land before the write.
            await waitUntil(timeout: 15) { lastTouched.count >= 1 }
            #expect(lastTouched.count == 1)
            try await Task.sleep(for: .milliseconds(500))
            try "hello".write(to: nested.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

            await waitUntil(timeout: 15) { lastTouched.count >= 2 }
            guard lastTouched.count >= 2, let touched = lastTouched.current else {
                Issue.record("no touched-repository firing for a write inside the newly-registered directory within the timeout")
                return
            }
            #expect(touched.directories.contains(root.path))
        }

        /// A classified non-ignored directory that is deleted and recreated (a branch switch does this)
        /// loses its inotify watch descriptor when it is removed (recreating it at the same path gets a
        /// new inode, which needs its own fresh `inotify_add_watch`), so the stale `classifiedDirectories`
        /// entry must be forgotten and the path reclassified, not just re-registered as-is. Recreating it
        /// WITH a populated nested `deep` subdirectory in the same step (rather than an empty directory)
        /// proves the fix walks the whole recreated subtree fresh: re-registering just the top path alone,
        /// with no reclassification, would restore coverage for `src/new` itself but leave `deep`
        /// unwatched, since inotify only reports the top of a newly created tree. `src/new` (a two-level
        /// path, so `src` itself is also freshly created up front) rather than a single top-level directory
        /// only so this reads like a realistic project layout; the mechanism under test concerns `src/new`
        /// specifically, the directory that gets deleted and recreated.
        @Test func aFileWrittenInsideADeletedAndRecreatedDirectoryIsStillObserved() async throws {
            let root = try makeRepository()
            defer { try? FileManager.default.removeItem(at: root) }
            let watch = WorkspaceWatch(workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.1, debounceCeiling: 1)

            let lastTouched = LastTouched()
            let (token, startError) = watch.subscribe { lastTouched.record($0) }
            defer { watch.unsubscribe(token) }
            #expect(startError == nil)

            let newDir = root.appendingPathComponent("src/new", isDirectory: true)
            try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
            await waitUntil(timeout: 15) { lastTouched.count >= 1 }
            #expect(lastTouched.count == 1)
            try await Task.sleep(for: .milliseconds(500))
            try "hello".write(to: newDir.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

            await waitUntil(timeout: 15) { lastTouched.count >= 2 }
            #expect(lastTouched.count == 2, "the write inside the freshly-classified directory must be observed")

            // Delete and recreate `src/new`, this time with a populated nested `deep` subdirectory created
            // in the same `createDirectory(withIntermediateDirectories:)` call: inotify only reports `new`'s
            // own creation, never `deep`'s, so a write inside `deep` below only succeeds if the fix
            // reclassified and expanded the whole recreated subtree rather than re-registering `new` alone.
            try FileManager.default.removeItem(at: newDir)
            let deepDir = newDir.appendingPathComponent("deep", isDirectory: true)
            try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
            // Settle time for the delete/recreate events themselves, and the reclassification they should
            // trigger, before writing inside, the same sequencing the initial creation above uses.
            try await Task.sleep(for: .milliseconds(1000))
            let countBeforeInnerWrite = lastTouched.count
            try "hello again".write(to: deepDir.appendingPathComponent("probe2.txt"), atomically: true, encoding: .utf8)

            await waitUntil(timeout: 15) { lastTouched.count > countBeforeInnerWrite }
            guard lastTouched.count > countBeforeInnerWrite, let touched = lastTouched.current else {
                Issue.record("no touched-repository firing for a write inside the deleted-and-recreated directory's nested subdirectory within the timeout")
                return
            }
            #expect(touched.directories.contains(root.path))
        }

        /// Fix for a subtree-registration gap: inotify only reports the TOP of a newly created or moved-in
        /// directory tree, since none of its descendants had a watch (or a parent with one) at creation
        /// time. Creating `a/b/c` with `createDirectory(withIntermediateDirectories:)` in one call reports
        /// only `a`'s own creation; without expanding that into every pre-existing descendant before
        /// registering, `b` and `c` never get their own inotify watch and a write inside `c` is silently
        /// dropped, exactly the same shape as `aFileInADirectoryCreatedAfterInstallIsStillObserved` above
        /// but three levels deep instead of one.
        @Test func aFileInAMultiLevelDirectoryTreeCreatedInOneShotAfterInstallIsStillObserved() async throws {
            let root = try makeRepository()
            defer { try? FileManager.default.removeItem(at: root) }
            let watch = WorkspaceWatch(workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.1, debounceCeiling: 1)

            let lastTouched = LastTouched()
            let (token, startError) = watch.subscribe { lastTouched.record($0) }
            defer { watch.unsubscribe(token) }
            #expect(startError == nil)

            let deep = root.appendingPathComponent("a/b/c", isDirectory: true)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            await waitUntil(timeout: 15) { lastTouched.count >= 1 }
            #expect(lastTouched.count == 1)
            // Give the registration (a combined ignore-listing spawn plus an `addPaths` call over `a` and
            // its already-on-disk descendants `a/b` and `a/b/c`) time to land before writing.
            try await Task.sleep(for: .milliseconds(500))
            try "hello".write(to: deep.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

            await waitUntil(timeout: 15) { lastTouched.count >= 2 }
            guard lastTouched.count >= 2, let touched = lastTouched.current else {
                Issue.record("no touched-repository firing for a write inside the deepest directory of a one-shot-created tree within the timeout")
                return
            }
            #expect(touched.directories.contains(root.path))
        }

        /// Fix for an unignore gap: `refreshIgnoreSetIfGitignoreChanged` replaces a repository's ignore set
        /// when its `.gitignore` changes, but a directory ignored at install time (and therefore never
        /// walked or watched, per `linuxWatchPaths`' own pruning) stayed permanently unobserved even after
        /// the rule excluding it was removed, unless something separately registered it. `build/` starts
        /// ignored (with a file already inside it, proving the directory has real, unwatched content before
        /// the rule is lifted), then `.gitignore` is rewritten empty; a write inside `build/` afterward must
        /// be observed. On Linux an ignore-set change that actually moves anything reinstalls the whole
        /// watch (see `aDirectoryThatBecomesIgnoredAfterAGitignoreEditTriggersAFullReinstall` below), which
        /// is what re-walks and re-registers `build/`; this test only asserts the resulting behavior.
        @Test func aDirectoryThatBecomesUnignoredAfterAGitignoreEditIsObservedAfterward() async throws {
            let root = try makeRepository()
            defer { try? FileManager.default.removeItem(at: root) }
            try "build/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            let buildDir = root.appendingPathComponent("build", isDirectory: true)
            try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
            try "placeholder".write(to: buildDir.appendingPathComponent("placeholder.txt"), atomically: true, encoding: .utf8)

            let watch = WorkspaceWatch(workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.1, debounceCeiling: 1)
            let lastTouched = LastTouched()
            let (token, startError) = watch.subscribe { lastTouched.record($0) }
            defer { watch.unsubscribe(token) }
            #expect(startError == nil)

            // Rewriting `.gitignore` empty is itself an accepted event (a `.gitignore` change always is),
            // so this firing alone proves nothing about `build/`'s new watch coverage; the write inside
            // `build/` afterward is what does.
            try "".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            await waitUntil(timeout: 15) { lastTouched.count >= 1 }
            #expect(lastTouched.count == 1)
            try await Task.sleep(for: .milliseconds(500))
            try "hello".write(to: buildDir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

            await waitUntil(timeout: 15) { lastTouched.count >= 2 }
            guard lastTouched.count >= 2, let touched = lastTouched.current else {
                Issue.record("no touched-repository firing for a write inside the newly-unignored directory within the timeout")
                return
            }
            #expect(touched.directories.contains(root.path))
        }

        /// The inverse of the unignore test above: a directory that
        /// BECOMES ignored keeps every inotify descriptor beneath it forever unless something removes them
        /// (inotify has no per-descriptor "stop watching" call this class uses elsewhere), so
        /// `refreshIgnoreSetIfGitignoreChanged` reinstalls the whole watch on Linux whenever the ignore set
        /// actually changes, applying the new set in both directions at once. A fake, install-counting
        /// watcher factory (the same pattern `aSubscribeAfterAnAddPathsFailureForcesAFullReinstallAndClearsTheError`
        /// above uses) proves the reinstall happened directly, since real inotify delivery timing after a
        /// descriptor removal is not a reliable thing to assert against; `build/` behaviorally losing its
        /// coverage after this reinstall is exactly what the sibling `linuxWatchPaths`/`FileSystemWatcher`
        /// install-time behavior already covers elsewhere, so this test only proves the reinstall itself.
        @Test func aDirectoryThatBecomesIgnoredAfterAGitignoreEditTriggersAFullReinstall() async throws {
            let root = try makeRepository()
            defer { try? FileManager.default.removeItem(at: root) }
            let buildDir = root.appendingPathComponent("build", isDirectory: true)
            try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

            final class FakeInjectedWatcher: FileSystemWatching, @unchecked Sendable {
                let onChange: @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
                init(onChange: @escaping @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void) { self.onChange = onChange }
                func start() async throws {}
                func stop() {}
                func addPaths(_ paths: [String]) throws {}
            }
            final class WatcherBox: @unchecked Sendable {
                private let lock = NSLock()
                private var watcher: FakeInjectedWatcher?
                private var installCount = 0
                func set(_ watcher: FakeInjectedWatcher) {
                    lock.lock()
                    self.watcher = watcher
                    installCount += 1
                    lock.unlock()
                }
                func fire(paths: [String]) {
                    lock.lock()
                    let watcher = self.watcher
                    lock.unlock()
                    watcher?.onChange(paths, false)
                }
                var count: Int {
                    lock.lock()
                    defer { lock.unlock() }
                    return installCount
                }
            }
            let box = WatcherBox()
            let watch = WorkspaceWatch(
                workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.05, debounceCeiling: 1,
                watcherFactory: { _, onChange in
                    let watcher = FakeInjectedWatcher(onChange: onChange)
                    box.set(watcher)
                    return watcher
                })

            let (token, startError) = watch.subscribe { _ in }
            defer { watch.unsubscribe(token) }
            #expect(startError == nil)
            #expect(box.count == 1)

            let gitignore = root.appendingPathComponent(".gitignore")
            try "build/\n".write(to: gitignore, atomically: true, encoding: .utf8)
            box.fire(paths: [gitignore.path])

            await waitUntil { box.count >= 2 }
            #expect(box.count == 2, "an ignore-set change that actually moves anything must trigger a full reinstall on Linux")
        }

        /// Fix for a Linux partial-failure gap: an `addPaths` failure (e.g. the inotify watch limit) sets
        /// `lastStartErrorText` but leaves the watcher installed, since only the new directory's
        /// registration failed, not the whole watch. `subscribe()`'s retry guard used to only fire on a nil
        /// watcher, so that recorded failure (and the missing coverage behind it) persisted through any
        /// number of retries; it must instead force a full reinstall whenever an error is recorded, exactly
        /// like a totally failed watch. An injected fake watcher (rather than real inotify) is used here
        /// deliberately, unlike this file's other tests: reproducing a genuine `addPaths` failure
        /// deterministically against the real kernel is not practical (see the doc comment on
        /// `aFileInADirectoryCreatedAfterInstallIsStillObserved` above for the same reasoning applied to
        /// `IN_Q_OVERFLOW`), while `WorkspaceWatch`'s own retry state machine is platform-independent logic
        /// best proven directly.
        @Test func aSubscribeAfterAnAddPathsFailureForcesAFullReinstallAndClearsTheError() async throws {
            struct FakeAddPathsError: Error, CustomStringConvertible { let description = "inotify watch limit reached" }
            let root = try makeRepository()
            defer { try? FileManager.default.removeItem(at: root) }

            final class FakeInjectedWatcher: FileSystemWatching, @unchecked Sendable {
                let onChange: @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void
                private let addPathsResult: Result<Void, any Error>
                init(onChange: @escaping @Sendable (_ paths: [String], _ mustRescan: Bool) -> Void, addPathsResult: Result<Void, any Error>) {
                    self.onChange = onChange
                    self.addPathsResult = addPathsResult
                }
                func start() async throws {}
                func stop() {}
                func addPaths(_ paths: [String]) throws { try addPathsResult.get() }
            }
            final class WatcherBox: @unchecked Sendable {
                private let lock = NSLock()
                private var watcher: FakeInjectedWatcher?
                private var installCount = 0
                func set(_ watcher: FakeInjectedWatcher) {
                    lock.lock()
                    self.watcher = watcher
                    installCount += 1
                    lock.unlock()
                }
                func fire(paths: [String]) {
                    lock.lock()
                    let watcher = self.watcher
                    lock.unlock()
                    watcher?.onChange(paths, false)
                }
                var count: Int {
                    lock.lock()
                    defer { lock.unlock() }
                    return installCount
                }
            }
            let box = WatcherBox()
            let watch = WorkspaceWatch(
                workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.05, debounceCeiling: 1,
                watcherFactory: { _, onChange in
                    // Only the FIRST installed watcher's `addPaths` fails; the reinstall this test provokes
                    // must create a second watcher whose `addPaths` succeeds, proving a genuinely fresh
                    // install ran rather than the same failure repeating.
                    let watcher = FakeInjectedWatcher(
                        onChange: onChange, addPathsResult: box.count == 0 ? .failure(FakeAddPathsError()) : .success(()))
                    box.set(watcher)
                    return watcher
                })

            let (firstToken, firstError) = watch.subscribe { _ in }
            #expect(firstError == nil)

            let newDirectory = root.appendingPathComponent("new-dir", isDirectory: true)
            try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
            box.fire(paths: [newDirectory.path])

            await waitUntil { watch.currentStartError() != nil }
            #expect(watch.currentStartError() != nil)
            #expect(box.count == 1, "the addPaths failure by itself must not trigger a reinstall")

            let (secondToken, secondError) = watch.subscribe { _ in }
            #expect(secondError == nil, "the retried install must have succeeded")
            #expect(box.count == 2, "a subscribe after a recorded error must force a full reinstall")
            #expect(watch.currentStartError() == nil)

            watch.unsubscribe(firstToken)
            watch.unsubscribe(secondToken)
        }

        /// `ls-files --ignored --directory` reports only the
        /// shallowest ignored ancestor (`vendor/`), never its descendants, so classifying an EXPANDED
        /// candidate list (the top directory plus every on-disk descendant) by exact-string membership in
        /// that reported set left every descendant "not ignored" and registered with inotify, e.g. an
        /// `npm install` inside a freshly created, ignored directory would grow the watch-descriptor count
        /// unbounded. The fix classifies the TOP-LEVEL candidate first (a prefix-aware match, not exact)
        /// and only expands into descendants when it comes back non-ignored, so an ignored root's subtree
        /// is never even walked into, let alone watched. Verified indirectly: since inotify only reports
        /// events for paths it has an explicit watch on, a write anywhere inside the ignored tree can only
        /// ever fire if some level of it wrongly got a watch installed.
        @Test func aMultiLevelDirectoryTreeCreatedInsideAnIgnoredDirectoryNeverFires() async throws {
            let root = try makeRepository()
            defer { try? FileManager.default.removeItem(at: root) }
            try "vendor/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try runGit(["add", "-A"], cwd: root.path)
            try runGit(
                ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "ignore vendor"], cwd: root.path)

            let watch = WorkspaceWatch(workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.1, debounceCeiling: 1)
            let lastTouched = LastTouched()
            let (token, startError) = watch.subscribe { lastTouched.record($0) }
            defer { watch.unsubscribe(token) }
            #expect(startError == nil)

            let deep = root.appendingPathComponent("vendor/a/b", isDirectory: true)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            // No firing is expected for the creation itself, since `vendor` is ignored; this just gives
            // classification (an ignore-listing spawn over the top-level `vendor` candidate) time to land.
            try await Task.sleep(for: .milliseconds(500))
            #expect(lastTouched.count == 0)

            try "hello".write(to: deep.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(500))
            #expect(lastTouched.count == 0, "a write inside vendor/a/b must never fire: no level of it should have an inotify watch")
        }

        /// inotify is non-recursive, so a directory newly created
        /// under a repository's `refs/` tree (a slash-containing branch name creates
        /// `refs/heads/feature/`; a fetch creates `refs/remotes/origin/...`) needs its own watch the same
        /// way any other new directory does, but `isUnclassifiedNewDirectory` never resolves a git-dir path
        /// to any repository at all (it only ever matches a WORKING directory). The ref directory is
        /// created directly here (rather than via `git branch feature/x`) to avoid a real branch-creation
        /// race; a write inside it afterward, standing in for git writing the loose ref file itself, must
        /// still be observed, which only holds if the fix actually registered the new directory.
        @Test func aFileWrittenInANewlyCreatedRefsSubdirectoryIsStillObserved() async throws {
            let root = try makeRepository()
            defer { try? FileManager.default.removeItem(at: root) }
            let watch = WorkspaceWatch(workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.1, debounceCeiling: 1)

            let lastTouched = LastTouched()
            let (token, startError) = watch.subscribe { lastTouched.record($0) }
            defer { watch.unsubscribe(token) }
            #expect(startError == nil)

            let refDir = root.appendingPathComponent(".git/refs/heads/feature", isDirectory: true)
            try FileManager.default.createDirectory(at: refDir, withIntermediateDirectories: true)
            // The ref directory's own creation is an accepted git-dir event (under `refs/`) and fires by
            // itself, so that firing is waited out first; only a SECOND firing, after the write inside it,
            // proves the new ref directory was registered with inotify.
            await waitUntil(timeout: 15) { lastTouched.count >= 1 }
            #expect(lastTouched.count == 1)
            try await Task.sleep(for: .milliseconds(500))
            try "abcdef0123456789abcdef0123456789abcdef01".write(to: refDir.appendingPathComponent("x"), atomically: true, encoding: .utf8)

            await waitUntil(timeout: 15) { lastTouched.count >= 2 }
            guard lastTouched.count >= 2, let touched = lastTouched.current else {
                Issue.record("no touched-repository firing for a write inside the newly-created refs subdirectory within the timeout")
                return
            }
            #expect(touched.directories.contains(root.path))
        }

        /// The watched WORKSPACE ROOT itself disappearing out from under a live subscription (deleted, or
        /// moved elsewhere) must surface as a live-refresh error rather than leaving the watch silently
        /// empty: `FileSystemWatcher`'s Linux drain loop treats the root's own `IN_DELETE_SELF`/
        /// `IN_MOVE_SELF` as needing a rescan (mirroring FSEvents' `RootChanged`), `WorkspaceWatch` answers
        /// a rescan with a full reinstall, and with the root gone every candidate path is `ENOENT`, so the
        /// reinstall itself fails with `WatchError.streamUnavailable`. A plain non-git directory (no `git
        /// init`) is used deliberately: the failure this exercises is the watcher's OWN root vanishing,
        /// unrelated to git.
        @Test func deletingTheWorkspaceRootSurfacesAsALiveRefreshError() async throws {
            let root = try makeTempDirectory()
            let watch = WorkspaceWatch(workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.05, debounceCeiling: 1)

            let (token, startError) = watch.subscribe { _ in }
            defer { watch.unsubscribe(token) }
            #expect(startError == nil)

            try FileManager.default.removeItem(at: root)

            await waitUntil { watch.currentStartError() != nil }
            guard let errorText = watch.currentStartError() else {
                Issue.record("no live-refresh error recorded after the watched root itself was deleted")
                return
            }
            #expect(
                errorText.contains("could not start") || errorText.contains(root.path),
                "the root vanishing must surface as a stream-unavailable failure or otherwise name the root, matching WatchError's own text: \(errorText)")
        }

        /// `git submodule update --init` into an ABSENT checkout directory does, in order: the
        /// superproject's `config` write (already an accepted map-rebuild trigger, but the checkout is not
        /// on disk yet), then `mkdir sub`, then writing `sub/.git` (the gitfile) moments later. inotify only
        /// reports the `mkdir` on the SUPERPROJECT's own watch; `classifyNewDirectories` classifies and
        /// registers `sub`'s own watch only after that single event is processed, so a gitfile write that
        /// already landed before that registration is never separately delivered as its own event, and
        /// `isRepositoryMapInvalidatingPath`'s `.git`-anywhere rule never fires for it. Without the fix,
        /// `sub` stays folded into the superproject's coverage until some unrelated event triggers the next
        /// reinstall. The gitfile write is emulated directly (`mkdir` then an immediate, synchronous `.git`
        /// write with no yield in between, guaranteed to finish before the daemon's own dispatch queue can
        /// even wake up to register a watch on the new directory) rather than run through the real `git
        /// submodule update --init`, since ordering that against a real git subprocess is not something
        /// this test can force deterministically.
        @Test func aSubmoduleCheckoutMaterializedIntoAnAbsentDirectoryIsMappedAsItsOwnRepository() async throws {
            let root = try makeRepository()
            defer { try? FileManager.default.removeItem(at: root) }
            let submoduleSource = try makeRepository()
            defer { try? FileManager.default.removeItem(at: submoduleSource) }

            try runGit(["-c", "protocol.file.allow=always", "submodule", "add", "-q", submoduleSource.path, "sub"], cwd: root.path)
            try runGit(
                ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add sub"], cwd: root.path)
            let subDir = root.appendingPathComponent("sub", isDirectory: true)
            // The gitlink and `.git/modules/sub` stay; only the checkout directory itself is gone, matching
            // a superproject cloned without `--recurse-submodules` or a submodule deinitialized by hand.
            try FileManager.default.removeItem(at: subDir)

            let watch = WorkspaceWatch(workspaceRoot: root.path, gitClient: RemoteWorkspaceGitClient(), debounceInterval: 0.05, debounceCeiling: 1)
            let lastTouched = LastTouched()
            let (token, startError) = watch.subscribe { lastTouched.record($0) }
            defer { watch.unsubscribe(token) }
            #expect(startError == nil)

            try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
            try "gitdir: ../.git/modules/sub\n".write(to: subDir.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            try runGit(["-C", subDir.path, "reset", "--hard"], cwd: root.path)

            await waitUntil(timeout: 15) { lastTouched.current?.all == true }
            #expect(
                lastTouched.current?.all == true,
                "a gitfile already present inside a newly registered directory must force a full map rebuild")

            try "changed".write(to: subDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

            await waitUntil(timeout: 15) { lastTouched.current?.directories.contains(subDir.path) == true }
            #expect(
                lastTouched.current?.directories.contains(subDir.path) == true,
                "sub must now be mapped as its own repository, not folded into the superproject's working directory")
        }
    }
#endif
