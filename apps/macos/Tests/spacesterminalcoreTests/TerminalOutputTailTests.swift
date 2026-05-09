import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalOutputTailTests: XCTestCase {
    func testTailReturnsLastLinesWithoutScanningWholeFileInCaller() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let text = (1...10).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try text.data(using: .utf8)?.write(to: url)

        let tailed = try TerminalOutputTail.tail(path: url.path, lineCount: 3)

        XCTAssertEqual(tailed, "line-8\nline-9\nline-10")
    }
}
