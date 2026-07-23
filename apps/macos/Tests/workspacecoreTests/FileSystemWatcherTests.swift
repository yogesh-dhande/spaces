// FileSystemWatcher is macOS-only (FSEvents); keep its tests off non-macOS builds.
#if os(macOS)

    import Foundation
    import XCTest

    @testable import workspacecore

    final class FileSystemWatcherTests: XCTestCase {
        /// Once per process: confirms fseventsd on this host actually delivers events within a
        /// generous window, independent of anything under test. #196 found the FSEvents-dependent
        /// tests below can miss even a very wide per-test ceiling when the machine-wide fseventsd
        /// daemon itself is degraded — widening those ceilings alone can't tell "product
        /// regression" apart from "this host's fseventsd is unhealthy". Computed once and reused
        /// so every FSEvents test pays for the diagnosis, not a repeated 30s probe.
        private static let fsEventsLivenessFailure: String? = {
            // Boxes the error thrown inside the Task below; DispatchSemaphore.wait() below the
            // Task establishes the happens-before edge that makes reading it back race-free.
            final class ErrorBox: @unchecked Sendable { var error: Error? }
            do {
                let directory = try makeTempDirectory()
                let delivered = DispatchSemaphore(value: 0)
                let watcher = FileSystemWatcher(paths: [directory.path], latency: 0.1) { paths in
                    if paths.contains(where: { $0.contains("liveness-probe.txt") }) { delivered.signal() }
                }

                let started = DispatchSemaphore(value: 0)
                let startFailure = ErrorBox()
                Task {
                    do { try await watcher.start() } catch { startFailure.error = error }
                    started.signal()
                }
                started.wait()
                if let error = startFailure.error { return "failed to start watcher: \(error)" }

                try "probe".write(to: directory.appendingPathComponent("liveness-probe.txt"), atomically: true, encoding: .utf8)
                let result = delivered.wait(timeout: .now() + 30)
                watcher.stop()
                guard result == .success else { return "no FSEvents callback delivered within 30s" }
                return nil
            } catch {
                return "probe setup failed: \(error)"
            }
        }()

        private struct FSEventsLivenessProbeFailed: Error {}

        /// FSEvents-dependent tests call this first so a degraded fseventsd on this host fails
        /// loudly as a machine-health problem instead of masquerading as a product regression.
        /// A hard failure (not XCTSkip) is deliberate: silently skipping would hide the signal
        /// that this host needs attention.
        private func requireHealthyFSEvents() throws {
            guard let failure = Self.fsEventsLivenessFailure else { return }
            XCTFail(
                "FSEvents liveness probe failed — fseventsd on this host is degraded (events not delivered within 30s). "
                    + "This is a machine-health problem, not a product regression: \(failure)")
            throw FSEventsLivenessProbeFailed()
        }

        // Tests that a change under a watched directory delivers a callback with the changed path.
        func testWatcherReportsChangesUnderWatchedDirectory() async throws {
            try requireHealthyFSEvents()
            let directory = try makeTempDirectory()
            let changed = XCTestExpectation(description: "file change reported")
            let watcher = FileSystemWatcher(paths: [directory.path], latency: 0.1) { paths in
                if paths.contains(where: { $0.contains("probe.txt") }) { changed.fulfill() }
            }
            try await watcher.start()
            defer { watcher.stop() }

            // Write after the stream is live so the change is observed rather than missed.
            try "hello".write(to: directory.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

            await fulfillment(of: [changed], timeout: 60)
        }

        // Exercises the deinit safety net: dropping the last reference to a running
        // watcher WITHOUT calling stop() must tear the FSEvents stream down cleanly. The
        // stream retains a callback box rather than `self`, so the watcher is free to
        // deinit while a callback may still be in flight; that callback dereferences the
        // live box, never the freed watcher. This asserts no crash/hang on the path; a
        // true use-after-free would only surface deterministically under the ASan lane,
        // and the box-ownership design is what makes the race structurally impossible.
        func testDroppingRunningWatcherWithoutStopTearsDownSafely() async throws {
            try requireHealthyFSEvents()
            let directory = try makeTempDirectory()
            let changed = XCTestExpectation(description: "file change reported")
            var watcher: FileSystemWatcher? = FileSystemWatcher(paths: [directory.path], latency: 0.1) { paths in
                if paths.contains(where: { $0.contains("probe.txt") }) { changed.fulfill() }
            }
            try await watcher?.start()
            try "hello".write(to: directory.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
            await fulfillment(of: [changed], timeout: 60)

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
