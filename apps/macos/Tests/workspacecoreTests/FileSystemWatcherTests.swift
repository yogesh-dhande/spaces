// FileSystemWatcher is macOS-only (FSEvents); keep its tests off non-macOS builds.
#if os(macOS)

    import CoreServices
    import Foundation
    import XCTest

    @testable import workspacecore

    final class FileSystemWatcherTests: XCTestCase {
        /// Once per process: confirms fseventsd on this host actually delivers events within a
        /// generous window. #196 found the FSEvents-dependent tests below can miss even a very
        /// wide per-test ceiling when the machine-wide fseventsd daemon itself is degraded —
        /// widening those ceilings alone can't tell "product regression" apart from "this host's
        /// fseventsd is unhealthy". The probe deliberately uses the raw FSEventStream C API, not
        /// FileSystemWatcher: if the watcher itself regresses, its tests must fail as product
        /// failures instead of being misdiagnosed here as host degradation. Computed once and
        /// reused so every FSEvents test pays for the diagnosis, not a repeated 30s probe.
        private static let fsEventsLivenessFailure: String? = {
            final class ProbeBox {
                let delivered = DispatchSemaphore(value: 0)
            }
            do {
                let directory = try makeTempDirectory()
                let box = ProbeBox()
                return withExtendedLifetime(box) {
                    var context = FSEventStreamContext(
                        version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil,
                        copyDescription: nil)
                    // Any delivery for the probe directory proves fseventsd is alive; no need to
                    // inspect paths or flags.
                    let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                        guard let info else { return }
                        Unmanaged<ProbeBox>.fromOpaque(info).takeUnretainedValue().delivered.signal()
                    }
                    guard
                        let stream = FSEventStreamCreate(
                            kCFAllocatorDefault, callback, &context, [directory.path] as CFArray,
                            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
                            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
                    else { return "FSEventStreamCreate failed" }

                    let queue = DispatchQueue(label: "test.fsevents-liveness-probe")
                    FSEventStreamSetDispatchQueue(stream, queue)
                    guard FSEventStreamStart(stream) else {
                        FSEventStreamInvalidate(stream)
                        FSEventStreamRelease(stream)
                        return "FSEventStreamStart failed"
                    }

                    do {
                        try "probe".write(
                            to: directory.appendingPathComponent("liveness-probe.txt"), atomically: true, encoding: .utf8)
                    } catch {
                        FSEventStreamStop(stream)
                        FSEventStreamInvalidate(stream)
                        FSEventStreamRelease(stream)
                        // The write may have created the file before throwing, so a callback can
                        // already be queued; drain it before `box` leaves the extended lifetime.
                        queue.sync {}
                        return "probe setup failed: \(error)"
                    }
                    let result = box.delivered.wait(timeout: .now() + 30)
                    FSEventStreamStop(stream)
                    FSEventStreamInvalidate(stream)
                    FSEventStreamRelease(stream)
                    // Drain any in-flight callback so `box` cannot be touched after this scope.
                    queue.sync {}
                    guard result == .success else { return "no FSEvents callback delivered within 30s" }
                    return nil
                }
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

        // Tests that a change under a watched directory delivers a callback with the changed path, and
        // that an ordinary change (no dropped/coalesced-past-precision events) reports `mustRescan == false`.
        func testWatcherReportsChangesUnderWatchedDirectory() async throws {
            try requireHealthyFSEvents()
            let directory = try makeTempDirectory()
            let changed = XCTestExpectation(description: "file change reported")
            let watcher = FileSystemWatcher(paths: [directory.path], latency: 0.1) { paths, mustRescan in
                if paths.contains(where: { $0.contains("probe.txt") }) {
                    XCTAssertFalse(mustRescan)
                    changed.fulfill()
                }
            }
            try await watcher.start()
            defer { watcher.stop() }

            // Write after the stream is live so the change is observed rather than missed.
            try "hello".write(to: directory.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

            await fulfillment(of: [changed], timeout: 60)
        }

        // A watch on the directory is what makes an atomic replace visible. Tools that rewrite a config
        // file in place do it by renaming a new file over the old one, which leaves a watch held on the
        // file itself pointing at the replaced inode; the Coding Agents rows depend on the directory
        // watch reporting the replacement instead. Asserts the inode really did change, so the test
        // cannot pass on a plain in-place write.
        func testWatcherReportsAFileReplacedByRename() async throws {
            try requireHealthyFSEvents()
            let directory = try makeTempDirectory()
            let file = directory.appendingPathComponent("config.toml")
            try "before".write(to: file, atomically: false, encoding: .utf8)
            let inodeBefore = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber

            let replaced = XCTestExpectation(description: "replacement reported")
            let watcher = FileSystemWatcher(paths: [directory.path], latency: 0.1) { paths, _ in
                if paths.contains(where: { $0.contains("config.toml") }) { replaced.fulfill() }
            }
            try await watcher.start()
            defer { watcher.stop() }

            // `atomically: true` writes a temp file and renames it over the destination.
            try "after".write(to: file, atomically: true, encoding: .utf8)

            await fulfillment(of: [replaced], timeout: 60)
            let inodeAfter = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
            XCTAssertNotEqual(inodeBefore, inodeAfter)
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
            var watcher: FileSystemWatcher? = FileSystemWatcher(paths: [directory.path], latency: 0.1) { paths, _ in
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
            let watcher = FileSystemWatcher(paths: []) { _, _ in }
            do {
                try await watcher.start()
                XCTFail("expected start() to throw for an empty path list")
            } catch {}
        }

        // The `streamUnavailable` description is what reaches the live-refresh banner verbatim; this pins
        // its exact wording so a future edit notices it changed.
        func testStreamUnavailableDescriptionIsUserReadable() {
            XCTAssertEqual("\(FileSystemWatcher.WatchError.streamUnavailable)", "the file watcher could not start")
        }
    }

#endif
