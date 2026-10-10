// Linux mirror of the macOS FSEvents coverage in FileSystemWatcherTests.swift. Only the Linux
// backend is exercised here since the macOS suite already covers FSEvents and depends on AppKit
// test support that does not build on Linux (see workspacecoreTests' absence from Package.swift's
// Linux testTargets, this file is the whitelisted exception, mirroring spacesterminalghosttyTests'
// and spacesdeviceapiTests' Linux-only source lists).
//
// Swift Testing (not XCTest) on purpose: run_linux_tests.sh's lane uses the swift-testing async-main
// runner, since an async XCTest method deadlocks on Linux (corelibs-xctest never drains queued async
// work on its blocked main thread).
#if os(Linux)
    import Foundation
    import Testing

    @testable import workspacecore

    /// A watcher callback's payload, boxed as a `Sendable` struct rather than a tuple: a generic helper
    /// constrained to `Sendable` cannot accept a tuple element (tuples cannot conform to protocols),
    /// even though the compiler treats a tuple of `Sendable` elements as implicitly `Sendable` at a
    /// `@Sendable` closure boundary.
    private struct WatcherEvent: Sendable {
        let paths: [String]
        let mustRescan: Bool
    }

    /// Records every `onChange` batch under a lock, standing in for `waitForEvent`'s `AsyncStream` shape
    /// when a test needs to prove an ABSENCE over a window rather than stop at the first match: an
    /// `AsyncStream` iterator is built to consume up to and including one matching element, which does not
    /// fit "collect whatever arrives for a fixed duration, then assert none of it matches."
    private final class BatchCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[String]] = []
        func record(_ batch: [String]) {
            lock.lock()
            batches.append(batch)
            lock.unlock()
        }
        var all: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return batches
        }
    }

    @Suite struct FileSystemWatcherLinuxInotifyTests {
        /// Container-local temporary directory, never the bind-mounted worktree: Docker Desktop's
        /// virtiofs/osxfs bind mount does not propagate host filesystem writes into the container as
        /// inotify events, so a test against the mounted repo would hang or silently miss changes
        /// depending on the host. `FileManager.default.temporaryDirectory` resolves to the container's
        /// own tmpfs, which does deliver inotify events.
        private func makeTempDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        /// Awaits `stream` until `matches` accepts an element, racing a 30s timeout so a regression that
        /// stops delivering events fails the test instead of hanging the suite.
        private func waitForEvent<Element: Sendable>(in stream: AsyncStream<Element>, matching matches: @escaping @Sendable (Element) -> Bool) async
            -> Element?
        {
            await withTaskGroup(of: Element?.self) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()
                    while let element = await iterator.next() { if matches(element) { return element } }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(30))
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result ?? nil
            }
        }

        @Test func watcherReportsChangesUnderWatchedDirectory() async throws {
            let directory = try makeTempDirectory()
            let (changes, continuation) = AsyncStream<WatcherEvent>.makeStream()
            let watcher = FileSystemWatcher(paths: [directory.path]) { paths, mustRescan in
                continuation.yield(WatcherEvent(paths: paths, mustRescan: mustRescan))
            }
            try await watcher.start()
            defer { watcher.stop() }

            try "hello".write(to: directory.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

            let event = await waitForEvent(in: changes) { $0.paths.contains { $0.contains("probe.txt") } }
            guard let event else {
                Issue.record("no inotify event named probe.txt within 30s")
                return
            }
            #expect(event.mustRescan == false)
        }

        /// `chmod +x` on a tracked file changes its rendered diff and `scopeSignature`
        /// (`scopeSignatureChangesWhenAnAlreadyDirtyFileIsChmoded`) but writes no new file content, so it
        /// reports only `IN_ATTRIB` (the `setattr` family: chmod/chown/utimes/truncate), never `IN_MODIFY`.
        /// Without `IN_ATTRIB` in the mask this event is silently dropped.
        @Test func watcherReportsAChmodOnAnExistingFileUnderTheWatchedDirectory() async throws {
            let directory = try makeTempDirectory()
            let file = directory.appendingPathComponent("script.sh")
            try "echo hi".write(to: file, atomically: true, encoding: .utf8)

            let (changes, continuation) = AsyncStream<WatcherEvent>.makeStream()
            let watcher = FileSystemWatcher(paths: [directory.path]) { paths, mustRescan in
                continuation.yield(WatcherEvent(paths: paths, mustRescan: mustRescan))
            }
            try await watcher.start()
            defer { watcher.stop() }

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

            let event = await waitForEvent(in: changes) { $0.paths.contains { $0.contains("script.sh") } }
            guard let event else {
                Issue.record("no inotify event named script.sh within 30s after chmod")
                return
            }
            #expect(event.mustRescan == false)
        }

        /// Directories registered after `start()` (e.g. one `WorkspaceWatch` discovers via a create
        /// event) must be watched too: `addPaths` is the only way to grow a running Linux watcher,
        /// since inotify is not recursive.
        @Test func addPathsWatchesADirectoryRegisteredAfterStart() async throws {
            let root = try makeTempDirectory()
            let nested = root.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

            let (changes, continuation) = AsyncStream<[String]>.makeStream()
            let watcher = FileSystemWatcher(paths: [root.path]) { paths, _ in continuation.yield(paths) }
            try await watcher.start()
            defer { watcher.stop() }
            try watcher.addPaths([nested.path])

            try "hello".write(to: nested.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

            let paths = await waitForEvent(in: changes) { $0.contains { $0.contains("probe.txt") } }
            if paths == nil { Issue.record("no inotify event named probe.txt under the newly-registered directory within 30s") }
        }

        /// A directory that vanished between being listed and registered here (e.g. a create followed
        /// immediately by a delete) is not a failure: `ENOENT` is skipped silently, matching
        /// `startOnQueue`'s own rule.
        @Test func addPathsOnAPathThatDoesNotExistIsSkippedSilently() async throws {
            let root = try makeTempDirectory()
            let watcher = FileSystemWatcher(paths: [root.path]) { _, _ in }
            try await watcher.start()
            defer { watcher.stop() }

            try watcher.addPaths([root.appendingPathComponent("does-not-exist").path])
        }

        /// `inotify_add_watch` fails `ENOTDIR` for a path that is not a directory, since the watch mask
        /// includes `IN_ONLYDIR`: a real, deterministic way to reproduce a non-`ENOENT` failure without
        /// exhausting the host's actual inotify watch limit. The thrown error must name both the path and
        /// the OS's own failure text.
        @Test func addPathsOnAPlainFileFailsWithThePathAndStrerrorText() async throws {
            let root = try makeTempDirectory()
            let plainFile = root.appendingPathComponent("not-a-directory.txt")
            try "hello".write(to: plainFile, atomically: true, encoding: .utf8)

            let watcher = FileSystemWatcher(paths: [root.path]) { _, _ in }
            try await watcher.start()
            defer { watcher.stop() }

            do {
                try watcher.addPaths([plainFile.path])
                Issue.record("expected addPaths to throw for a non-directory path")
            } catch {
                let text = "\(error)"
                #expect(text.contains(plainFile.path))
                #expect(text.contains("Not a directory") || text.contains("ENOTDIR"))
            }
        }

        /// `IN_MOVE_SELF` fires on a watched directory's own descriptor when it is moved or renamed,
        /// regardless of destination, but the kernel does not drop the watch on its own the way a delete
        /// does (no automatic `IN_IGNORED`). Left unhandled, the watch keeps reporting from wherever the
        /// directory ended up, still mapped to its stale OLD path: this moves `a` to a sibling directory
        /// OUTSIDE the watched root (so nothing re-registers it, unlike a destination still inside the
        /// workspace, which `WorkspaceWatch` picks up again through the parent's `IN_MOVED_TO`), then writes
        /// inside it at the new location and asserts nothing is ever reported under the old path.
        /// The routing rules for this are also covered directly in `FileSystemWatcherInotifyRoutingTests`.
        ///
        /// Root's `IN_MOVED_FROM` for the child name and `a`'s own `IN_MOVE_SELF` both come from the one
        /// `rename()` and both name the bare old path, but they are separate kernel events: the reader can
        /// wake between them and report each in its own batch, which CI once caught arriving after the
        /// writes below. The stale-path checks therefore look only for a child of an old path
        /// (`<old>/<name>`), which is what a write under a stale mapping reports, and never for the bare old
        /// path, which the move itself legitimately reports any number of times.
        ///
        /// Also watches `a/b`, a descendant registered as its OWN separate descriptor (inotify is not
        /// recursive): `IN_MOVE_SELF` fires only for `a`'s own descriptor when `a` moves, never for `b`'s,
        /// even though `b` moves right along with it, so `IN_MOVE_SELF` handling must also drop every
        /// descendant descriptor whose path sits beneath the moved directory, not just the moved directory's
        /// own. A write inside the moved `b` at its new location must never be reported under its old path
        /// either.
        @Test func movingAWatchedDirectoryOutsideTheRootDropsItsStaleWatchMapping() async throws {
            let root = try makeTempDirectory()
            let a = root.appendingPathComponent("a", isDirectory: true)
            let b = a.appendingPathComponent("b", isDirectory: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            let outsideParent = try makeTempDirectory()
            let destination = outsideParent.appendingPathComponent("a", isDirectory: true)

            let collector = BatchCollector()
            let watcher = FileSystemWatcher(paths: [root.path, a.path, b.path]) { paths, _ in collector.record(paths) }
            try await watcher.start()
            defer { watcher.stop() }

            try FileManager.default.moveItem(at: a, to: destination)

            // Poll rather than a fixed sleep: the move's events land within milliseconds on a local
            // tmpfs, and a bounded 5s poll fails outright on a real regression instead of flaking under
            // host load the way a single short fixed sleep would.
            var sawMoveReport = false
            for _ in 0..<500 {
                if collector.all.contains(where: { $0.contains(a.path) }) {
                    sawMoveReport = true
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(sawMoveReport, "no onChange reported the moved directory's old path within 5s")

            let movedB = destination.appendingPathComponent("b", isDirectory: true)
            try "hello".write(to: destination.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
            try "hello".write(to: movedB.appendingPathComponent("probe2.txt"), atomically: true, encoding: .utf8)

            // Give a stale mapping every chance to misfire: without dropping the watch on `IN_MOVE_SELF`,
            // these writes at the moved directories' new, unwatched locations would still land on their
            // same kernel watch descriptors and be reported under their STALE old paths.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let staleBatches = collector.all.filter { batch in batch.contains { $0.hasPrefix(a.path + "/") } }
            #expect(staleBatches.isEmpty, "a write at either moved directory's new location must never be reported under its old path")
            let staleDescendantBatches = collector.all.filter { batch in batch.contains { $0.hasPrefix(b.path + "/") } }
            #expect(
                staleDescendantBatches.isEmpty,
                "a write inside the moved descendant directory's new location must never be reported under its old path")
        }

        /// A watched INSTALL ROOT (one of `paths` passed to `init`) itself disappearing must be reported as
        /// needing a rescan, mirroring FSEvents' `kFSEventStreamEventFlagRootChanged`: nothing watches the
        /// root's own parent, so a directory later recreated at the same path would otherwise produce no
        /// event at all, leaving the watcher silently empty or partial instead of prompting the reinstall
        /// (or, if the root stays gone, the visible failure) a rescan is meant to trigger.
        @Test func deletingAWatchedRootReportsARescan() async throws {
            let root = try makeTempDirectory()
            let (changes, continuation) = AsyncStream<WatcherEvent>.makeStream()
            let watcher = FileSystemWatcher(paths: [root.path]) { paths, mustRescan in
                continuation.yield(WatcherEvent(paths: paths, mustRescan: mustRescan))
            }
            try await watcher.start()
            defer { watcher.stop() }

            try FileManager.default.removeItem(at: root)

            let event = await waitForEvent(in: changes) { $0.mustRescan }
            guard let event else {
                Issue.record("no rescan reported after the watched root itself was deleted within 30s")
                return
            }
            #expect(event.mustRescan)
        }

        /// Counts this process's inotify instances. `/proc/self/fd` lists the listing's own descriptor too,
        /// whose `readlink` is not an inotify one, so it never inflates the count.
        private func inotifyInstanceCount() -> Int {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
            return names.filter { name in
                (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/" + name)) == "anon_inode:inotify"
            }.count
        }

        /// Linux caps inotify instances per user (shared with every other program the user runs), so
        /// the process must hold one however many watchers run. Another suite may have created the shared
        /// instance already, hence "at most one" for the first batch and exactly zero for the second.
        @Test func manyWatchersShareOneInotifyInstance() async throws {
            let before = inotifyInstanceCount()
            var watchers: [FileSystemWatcher] = []
            for _ in 0..<3 {
                let watcher = FileSystemWatcher(paths: [try makeTempDirectory().path]) { _, _ in }
                try await watcher.start()
                watchers.append(watcher)
            }
            let afterFirstBatch = inotifyInstanceCount()
            for _ in 0..<3 {
                let watcher = FileSystemWatcher(paths: [try makeTempDirectory().path]) { _, _ in }
                try await watcher.start()
                watchers.append(watcher)
            }
            let afterSecondBatch = inotifyInstanceCount()
            for watcher in watchers { watcher.stop() }

            #expect(afterFirstBatch - before <= 1)
            #expect(afterSecondBatch == afterFirstBatch)
        }

        @Test func twoWatchersOnTheSameDirectoryBothReceiveAnEvent() async throws {
            let directory = try makeTempDirectory()
            let (firstChanges, firstContinuation) = AsyncStream<[String]>.makeStream()
            let (secondChanges, secondContinuation) = AsyncStream<[String]>.makeStream()
            let first = FileSystemWatcher(paths: [directory.path]) { paths, _ in firstContinuation.yield(paths) }
            let second = FileSystemWatcher(paths: [directory.path]) { paths, _ in secondContinuation.yield(paths) }
            try await first.start()
            try await second.start()
            defer {
                first.stop()
                second.stop()
            }

            try "hello".write(to: directory.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

            let firstPaths = await waitForEvent(in: firstChanges) { $0.contains { $0.contains("probe.txt") } }
            let secondPaths = await waitForEvent(in: secondChanges) { $0.contains { $0.contains("probe.txt") } }
            #expect(firstPaths != nil, "the first watcher received no event within 30s")
            #expect(secondPaths != nil, "the second watcher received no event within 30s")
        }

        /// Both watchers share one kernel watch descriptor on the directory; removing it when the first
        /// stops would silently blind the second.
        @Test func stoppingOneOfTwoWatchersOnTheSameDirectoryLeavesTheOtherWatching() async throws {
            let directory = try makeTempDirectory()
            let first = FileSystemWatcher(paths: [directory.path]) { _, _ in }
            let (changes, continuation) = AsyncStream<[String]>.makeStream()
            let second = FileSystemWatcher(paths: [directory.path]) { paths, _ in continuation.yield(paths) }
            try await first.start()
            try await second.start()
            defer { second.stop() }

            first.stop()
            // `stop()` is async onto the shared queue; this sync read queues behind it.
            _ = FileSystemWatcherInotifyInstance.shared.hasRegistration(atPath: directory.path)

            try "hello".write(to: directory.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

            let paths = await waitForEvent(in: changes) { $0.contains { $0.contains("probe.txt") } }
            #expect(paths != nil, "the remaining watcher received no event within 30s after the other stopped")
        }

        @Test func kernelWatchIsRemovedOnceEveryWatcherOnTheDirectoryStops() async throws {
            let directory = try makeTempDirectory()
            // Keyed by this test's unique directory: other suites share the instance and run concurrently.
            let instance = FileSystemWatcherInotifyInstance.shared
            let first = FileSystemWatcher(paths: [directory.path]) { _, _ in }
            let second = FileSystemWatcher(paths: [directory.path]) { _, _ in }
            try await first.start()
            try await second.start()
            #expect(instance.hasRegistration(atPath: directory.path))

            // Each read queues behind the preceding async `stop()` on the shared queue.
            first.stop()
            #expect(instance.hasRegistration(atPath: directory.path), "the second watcher still needs the kernel watch")
            second.stop()
            #expect(!instance.hasRegistration(atPath: directory.path))
        }
    }
#endif
