import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalReplayOutputHistoryTests: XCTestCase {
    func testLoadsReplayableOutputWhenWithinBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outputPath = root.appendingPathComponent("output.log").path
        try "alpha\nbeta\n".write(toFile: outputPath, atomically: true, encoding: .utf8)

        let history = try XCTUnwrap(TerminalReplayOutputHistory.load(path: outputPath, maxByteCount: 64))

        XCTAssertEqual(history.totalByteCount, 11)
        XCTAssertEqual(String(data: try XCTUnwrap(history.data), encoding: .utf8), "alpha\nbeta\n")
    }

    func testOmitsDataWhenOutputExceedsBudgetButKeepsByteCount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outputPath = root.appendingPathComponent("output.log").path
        try "0123456789".write(toFile: outputPath, atomically: true, encoding: .utf8)

        let history = try XCTUnwrap(TerminalReplayOutputHistory.load(path: outputPath, maxByteCount: 4))

        XCTAssertEqual(history.totalByteCount, 10)
        XCTAssertNil(history.data)
    }
}
