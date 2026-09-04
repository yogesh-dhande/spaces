import Foundation
import XCTest

@testable import spacesterminalcore

/// The DEBUG-only on-device performance log rotates by size so an unattended run cannot grow it without
/// bound between Mac-side pulls (see `SpacesDeviceTerminalPerformanceLogger.appendJSONLine`). These tests
/// drive that rotation directly through the internal `appendJSONLine(_:to:maximumBytes:)` seam with a
/// tiny threshold, rather than writing megabytes of fixture lines through the real 8 MB default.
final class SpacesDeviceTerminalPerformanceLoggerTests: XCTestCase {
    private var directory: URL!
    private var logPath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-perf-log-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logPath = directory.appendingPathComponent("device-perf.jsonl").path
    }

    override func tearDownWithError() throws {
        SpacesDeviceTerminalPerformanceLogger.resetDefaultLogPathForTesting()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testRotationMovesTheFullFileAsideAndContinuesInAFreshFile() throws {
        // Each line is a dozen-odd bytes; a maximum this small forces several rotations across 20
        // appends without needing megabytes of fixture data, and the assertions below only depend on the
        // last line written, not on exactly which append triggered which rotation.
        for index in 0..<20 { appendLine(index) }

        let rotatedPath = logPath + ".1"
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedPath), "the full file must have rotated aside")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath), "a fresh file must exist at the original path")

        let freshLines = try linesInFile(at: logPath)
        XCTAssertFalse(freshLines.isEmpty, "the fresh file must contain the line that triggered its own rotation")
        XCTAssertEqual(freshLines.last.flatMap(decodedCount), 19, "the fresh file's last line must be the most recently appended one")

        let rotatedLines = try linesInFile(at: rotatedPath)
        XCTAssertFalse(rotatedLines.isEmpty, "the rotated-aside file must keep the lines that were in it")
        XCTAssertTrue((rotatedLines.compactMap(decodedCount).max() ?? -1) < 19, "the rotated-aside file must predate the fresh file's lines")
    }

    func testASecondRotationReplacesTheOldRotatedFile() throws {
        for index in 0..<20 { appendLine(index) }
        let rotatedPath = logPath + ".1"
        let firstRotationContents = try Data(contentsOf: URL(fileURLWithPath: rotatedPath))
        XCTAssertFalse(firstRotationContents.isEmpty)

        // Enough further appends to force at least one more rotation of the fresh file the first
        // rotation left behind.
        for index in 20..<40 { appendLine(index) }

        let secondRotationContents = try Data(contentsOf: URL(fileURLWithPath: rotatedPath))
        XCTAssertNotEqual(secondRotationContents, firstRotationContents, "the later rotation must replace the earlier one, not append to it")

        let freshLines = try linesInFile(at: logPath)
        XCTAssertEqual(freshLines.last.flatMap(decodedCount), 39, "the fresh file after the second round of rotations must hold the latest line")
    }

    /// Regression test for `writeQueue`: production no longer serializes `appendJSONLine` with a lock,
    /// it serializes by routing every `emit` through the single serial `writeQueue`. `emit` itself cannot
    /// drive rotation with a small `maximumBytes` (it always uses the real 8 MB default), so this drives
    /// `appendJSONLine` the same way `emit` does, through `writeQueue.async`, rather than calling it
    /// directly: that exercises the real serialization path with less new test-only surface than adding a
    /// way to override `emit`'s threshold. Every count is submitted from a different thread via
    /// `concurrentPerform`, mirroring `emit`'s callers (the main actor and several engine/session queues),
    /// then `flush()` waits for the queue to drain before asserting. `count` and `maximumBytes`
    /// are chosen so the run crosses the rotation threshold exactly once regardless of submission order,
    /// so every count must land in exactly one of the two files with none lost, and `.1` must be non-empty.
    func testConcurrentWritesThroughTheQueueAcrossTheRotationThresholdLoseNoLine() throws {
        // Every line is ~13-14 bytes; 40 of them total ~520-560 bytes, comfortably more than one
        // `maximumBytes: 300` but under two, so the run rotates exactly once regardless of write order.
        // Captures `path` rather than calling the instance method `appendLine`, so the `@Sendable`
        // closure below captures only that immutable String instead of the non-Sendable test case.
        let count = 40
        let path = logPath!
        DispatchQueue.concurrentPerform(iterations: count) { index in
            SpacesDeviceTerminalPerformanceLogger.writeQueue.async {
                SpacesDeviceTerminalPerformanceLogger.appendJSONLine(Fixture(count: index), to: path, maximumBytes: 300)
            }
        }
        SpacesDeviceTerminalPerformanceLogger.flush()

        let rotatedPath = logPath + ".1"
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedPath), "the queued writes must still have crossed the threshold and rotated")

        let rotatedLines = try linesInFile(at: rotatedPath)
        XCTAssertFalse(rotatedLines.isEmpty, "the rotated-aside file must not be empty")

        let freshLines = try linesInFile(at: logPath)
        let allCounts = (rotatedLines + freshLines).compactMap(decodedCount)
        XCTAssertEqual(allCounts.count, count, "every queued line must be decodable, with none corrupted by an interleaved write")
        XCTAssertEqual(Set(allCounts), Set(0..<count), "every queued count must land in exactly one of the two files, with none lost")
    }

    /// `emit` no longer writes to disk on the caller: it forces the event, then hands it to `writeQueue`
    /// and returns. This proves that queue actually reaches `appendJSONLine` and drains to disk, using
    /// `flush()` in place of a sleep/poll loop, rather than only proving `emit` calls
    /// `sinkForTesting` (which the other DEBUG-only performance tests already cover).
    func testEmitFollowedByFlushLeavesTheLineOnDisk() throws {
        SpacesDeviceTerminalPerformanceLogger.configureDefaultLogPath(logPath)

        SpacesDeviceTerminalPerformanceLogger.emit(
            SpacesDeviceTerminalPerformanceEvent(sessionID: "session-1", source: "test", name: "paint")
        )
        SpacesDeviceTerminalPerformanceLogger.flush()

        let lines = try linesInFile(at: logPath)
        XCTAssertEqual(lines.count, 1, "the flushed queue must have appended exactly the one emitted line")
        XCTAssertTrue(lines[0].contains("\"session-1\""), "the appended line must contain the emitted event's session id")
    }

    // MARK: - Fixtures

    private struct Fixture: Codable, Equatable { let count: Int }

    private func appendLine(_ count: Int, maximumBytes: Int = 30) {
        SpacesDeviceTerminalPerformanceLogger.appendJSONLine(Fixture(count: count), to: logPath, maximumBytes: maximumBytes)
    }

    private func linesInFile(at path: String) throws -> [String] {
        let contents = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        return contents.split(separator: "\n").map(String.init)
    }

    private func decodedCount(_ line: String) -> Int? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Fixture.self, from: data).count
    }
}
