// FileSystemWatcher is macOS-only (FSEvents); keep its tests off non-macOS builds.
#if os(macOS)

    import Foundation
    import XCTest

    @testable import workspacecore

    final class FileSystemWatcherTests: XCTestCase {
        // Tests that a change under a watched directory delivers a callback with the changed path.
        func testWatcherReportsChangesUnderWatchedDirectory() async throws {
            let directory = try makeTempDirectory()
            let changed = XCTestExpectation(description: "file change reported")
            let watcher = FileSystemWatcher(paths: [directory.path], latency: 0.1) { paths in
                if paths.contains(where: { $0.contains("probe.txt") }) { changed.fulfill() }
            }
            try await watcher.start()
            defer { watcher.stop() }

            // Write after the stream is live so the change is observed rather than missed.
            try "hello".write(to: directory.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

            await fulfillment(of: [changed], timeout: 10)
        }

        // Exercises the deinit safety net: dropping the last reference to a running
        // watcher WITHOUT calling stop() must tear the FSEvents stream down cleanly. The
        // stream retains a callback box rather than `self`, so the watcher is free to
        // deinit while a callback may still be in flight; that callback dereferences the
        // live box, never the freed watcher. This asserts no crash/hang on the path; a
        // true use-after-free would only surface deterministically under the ASan lane,
        // and the box-ownership design is what makes the race structurally impossible.
        func testDroppingRunningWatcherWithoutStopTearsDownSafely() async throws {
            let directory = try makeTempDirectory()
            let changed = XCTestExpectation(description: "file change reported")
            var watcher: FileSystemWatcher? = FileSystemWatcher(paths: [directory.path], latency: 0.1) { paths in
                if paths.contains(where: { $0.contains("probe.txt") }) { changed.fulfill() }
            }
            try await watcher?.start()
            try "hello".write(to: directory.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
            await fulfillment(of: [changed], timeout: 10)

            // Drop without stop(); deinit schedules the async teardown on the watcher queue.
            watcher = nil
            // Let the deinit-scheduled teardown drain on the watcher queue.
            try await Task.sleep(for: .milliseconds(300))
        }

        // Tests that starting with no paths fails loudly instead of silently watching nothing.
        func testStartWithoutPathsThrows() async {
            let watcher = FileSystemWatcher(paths: []) { _ in }
            do {
                try await watcher.start()
                XCTFail("expected start() to throw for an empty path list")
            } catch {}
        }
    }

#endif
