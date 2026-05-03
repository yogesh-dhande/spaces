import XCTest

@testable import systembridge

final class TmuxAdapterTests: XCTestCase {
    func testParseWindowPreservesVisibleSentinelInsideWindowName() {
        let adapter = TmuxAdapter()
        let separator = "\u{1F}"
        let line = ["@12", "3", "frontend <<<SPACES_FIELD>>> debug", "workspace <<<SPACES_FIELD>>> session", "1", "4242"].joined(separator: separator)

        let window = adapter.parseWindow(line: line)

        XCTAssertEqual(window?.id, "@12")
        XCTAssertEqual(window?.index, 3)
        XCTAssertEqual(window?.name, "frontend <<<SPACES_FIELD>>> debug")
        XCTAssertEqual(window?.sessionName, "workspace <<<SPACES_FIELD>>> session")
        XCTAssertEqual(window?.isActive, true)
        XCTAssertEqual(window?.panePID, 4242)
    }
}
