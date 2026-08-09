import XCTest

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@testable import spacesterminalcore

final class RuntimeLogTrimmingTests: XCTestCase {
    func testUnderCapFileIsUntouched() throws {
        let path = try makeTemporaryFile(contents: "small log\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let original = try Data(contentsOf: URL(fileURLWithPath: path))

        RuntimeLogTrimming.trimIfOversized(path: path)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
    }

    func testOverCapFileIsTrimmedToTailOnALineBoundary() throws {
        // Build oversized content as many short, numbered lines so the exact tail is predictable: the
        // trim keeps the last `retainedSizeAfterTrimBytes` and then cuts forward to the next newline.
        let path = try makeOversizedNumberedLinesFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let lineCount = try numberedLineCount(forFileAtPath: path)

        RuntimeLogTrimming.trimIfOversized(path: path)

        let trimmed = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertLessThanOrEqual(trimmed.count, RuntimeLogTrimming.retainedSizeAfterTrimBytes)
        let trimmedText = try XCTUnwrap(String(data: trimmed, encoding: .utf8))
        let expectedLastLine = "line-\(String(format: "%010d", lineCount - 1))\n"
        XCTAssertTrue(trimmedText.hasSuffix(expectedLastLine), trimmedText)
        // Starts on a line boundary: every kept line matches the fixed-width format, none is a
        // truncated fragment of the line that was cut.
        for line in trimmedText.split(separator: "\n") { XCTAssertTrue(line.hasPrefix("line-"), String(line)) }
    }

    func testMissingFileIsANoOp() {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString).log").path
        RuntimeLogTrimming.trimIfOversized(path: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// The doc comment on `trimIfOversized` argues it is safe against a writer holding an O_APPEND
    /// descriptor open across the call, because a rewrite-through-truncate keeps the descriptor and the
    /// path pointing at the same inode. This proves that directly with a real O_APPEND file descriptor
    /// opened before the trim: a write through it afterward must land right after the trimmed tail, not
    /// get lost in an unlinked copy of the old, oversized file (which a temp-file-and-rename trim would
    /// produce instead).
    func testWriteThroughOAppendDescriptorOpenedBeforeTrimLandsInTheTrimmedFile() throws {
        let path = try makeOversizedNumberedLinesFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let originalSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)

        let descriptor = open(path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        RuntimeLogTrimming.trimIfOversized(path: path)

        let appendedLine = "appended-after-trim\n"
        let writtenCount = appendedLine.withCString { write(descriptor, $0, strlen($0)) }
        XCTAssertEqual(writtenCount, appendedLine.utf8.count)

        let finalText = try XCTUnwrap(String(data: Data(contentsOf: URL(fileURLWithPath: path)), encoding: .utf8))
        XCTAssertTrue(finalText.hasSuffix(appendedLine), finalText)
        // The appended write landed right after the trimmed (small) tail, not at the end of the
        // original oversized file — proof the descriptor is tracking the same, now-shorter inode.
        XCTAssertLessThan(finalText.utf8.count, originalSize)
    }

    private func makeTemporaryFile(contents: String) throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("runtime-log-trim-\(UUID().uuidString).log").path
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func makeOversizedNumberedLinesFile() throws -> String {
        let lineText = "line-0000000000\n"
        let lineCount = (RuntimeLogTrimming.maximumSizeBeforeTrimBytes / lineText.utf8.count) + 1000
        var content = ""
        content.reserveCapacity(lineCount * lineText.utf8.count)
        for index in 0..<lineCount { content += "line-\(String(format: "%010d", index))\n" }
        let path = try makeTemporaryFile(contents: content)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
        XCTAssertGreaterThan(size, RuntimeLogTrimming.maximumSizeBeforeTrimBytes)
        return path
    }

    private func numberedLineCount(forFileAtPath path: String) throws -> Int {
        let content = try XCTUnwrap(String(data: Data(contentsOf: URL(fileURLWithPath: path)), encoding: .utf8))
        return content.split(separator: "\n").count
    }
}
