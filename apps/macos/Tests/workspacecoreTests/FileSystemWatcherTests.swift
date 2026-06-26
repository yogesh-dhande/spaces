// FileSystemWatcher is macOS-only (FSEvents); keep its tests off non-macOS builds.
#if os(macOS)

    import Foundation
    import XCTest

    @testable import workspacecore

final class FileSystemWatcherTests: XCTestCase {
    // Tests that a change under a watched directory delivers a callback with the changed path.
    func testWatcherReportsChangesUnderWatchedDirectory() throws {
        let directory = try makeTempDirectory()
        let changed = XCTestExpectation(description: "file change reported")
        let watcher = FileSystemWatcher(paths: [directory.path], latency: 0.1) { paths in
            if paths.contains(where: { $0.contains("probe.txt") }) { changed.fulfill() }
        }
        try watcher.start()
        defer { watcher.stop() }

        // Write after the stream is live so the change is observed rather than missed.
        try "hello".write(to: directory.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)

        wait(for: [changed], timeout: 10)
    }

    // Tests that starting with no paths fails loudly instead of silently watching nothing.
    func testStartWithoutPathsThrows() {
        let watcher = FileSystemWatcher(paths: []) { _ in }
        XCTAssertThrowsError(try watcher.start())
    }
}

#endif
