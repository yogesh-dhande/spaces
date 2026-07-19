import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalTranscriptTrimTests: XCTestCase {
    private func makeTranscriptFile() throws -> (url: URL, handle: FileHandle) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        addTeardownBlock {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
        return (url, handle)
    }

    func testTrimIsANoOpBelowTrigger() throws {
        let (url, handle) = try makeTranscriptFile()
        let payload = Data(repeating: 0x61, count: 500)
        try handle.write(contentsOf: payload)

        let newEnd = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: 500, triggerBytes: 1000, retainedBytes: 400)

        XCTAssertEqual(newEnd, 500)
        XCTAssertEqual(try Data(contentsOf: url), payload, "Transcript below the trigger must be left untouched.")
    }

    func testTrimKeepsNewestRetainedBytesWhenOverTrigger() throws {
        let (url, handle) = try makeTranscriptFile()
        // 1200 unique bytes so we can prove the NEWEST bytes survive and the oldest are dropped.
        let total = 1200
        var payload = Data(capacity: total)
        for index in 0..<total { payload.append(UInt8(index % 251)) }
        try handle.write(contentsOf: payload)

        let newEnd = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(total), triggerBytes: 1000, retainedBytes: 400)

        XCTAssertEqual(newEnd, 400)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, 400, "The file must be bounded to the retained size.")
        XCTAssertEqual(onDisk, payload.suffix(400), "Trim must preserve the newest bytes, dropping only the oldest head bytes.")
    }

    func testAppendsContinueAtNewEndAfterTrim() throws {
        let (url, handle) = try makeTranscriptFile()
        let payload = Data(repeating: 0x62, count: 1200)
        try handle.write(contentsOf: payload)

        _ = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: 1200, triggerBytes: 1000, retainedBytes: 400)
        // The write handle must be positioned at the new end so appends do not overwrite retained bytes.
        let appended = Data("APPENDED".utf8)
        try handle.write(contentsOf: appended)

        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, 400 + appended.count)
        XCTAssertEqual(onDisk.suffix(appended.count), appended)
    }

    func testTrimmedTranscriptStillReplaysNewestLinesThroughTail() throws {
        // The bound must preserve enough history that a suffix/replay consumer still renders the newest
        // scrollback. Build a line-oriented transcript larger than the trigger, trim, then render the tail.
        let (url, handle) = try makeTranscriptFile()
        var payload = Data()
        var lineIndex = 0
        while payload.count <= 1000 {
            payload.append(Data("SEQ \(String(format: "%05d", lineIndex))\n".utf8))
            lineIndex += 1
        }
        let lastLineIndex = lineIndex - 1
        try handle.write(contentsOf: payload)

        _ = try TerminalTranscriptTrim.trimIfNeeded(
            outputPath: url.path, writeHandle: handle, currentEndOffset: UInt64(payload.count), triggerBytes: 1000, retainedBytes: 400)

        let tail = try TerminalOutputTail.tail(path: url.path, lineCount: 3)
        XCTAssertTrue(tail.contains("SEQ \(String(format: "%05d", lastLineIndex))"), "Newest line must survive the trim: \(tail)")
    }

    func testConfiguredBoundKeepsFullScrollbackBudget() {
        // Every consumer caps its read at defaultMaxBytes, so the retained size must exceed that budget.
        XCTAssertGreaterThan(TerminalScrollbackBudget.liveTranscriptRetainedBytes, TerminalScrollbackBudget.defaultMaxBytes)
        XCTAssertGreaterThan(
            TerminalScrollbackBudget.liveTranscriptTrimTriggerBytes, TerminalScrollbackBudget.liveTranscriptRetainedBytes)
    }
}
