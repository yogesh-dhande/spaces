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

    func testParseWindowIDTrimsWhitespace() {
        let adapter = TmuxAdapter()

        let windowID = adapter.parseWindowID(output: "  @7 \n")

        XCTAssertEqual(windowID, "@7")
    }

    func testParseWindowIDReturnsUnderscoreDelimitedOutputVerbatim() {
        let adapter = TmuxAdapter()

        let windowID = adapter.parseWindowID(output: "@0_1_dev server_session_1_4242\n")

        XCTAssertEqual(windowID, "@0_1_dev server_session_1_4242")
    }

    func testParseCreatedWindowHandlesSanitizedUnderscoreDelimiters() {
        let adapter = TmuxAdapter()

        let window = adapter.parseCreatedWindow(output: "@0_1_1_4242\n", fallbackName: "dev server", sessionName: "spaces-session")

        XCTAssertEqual(window?.id, "@0")
        XCTAssertEqual(window?.index, 1)
        XCTAssertEqual(window?.name, "dev server")
        XCTAssertEqual(window?.sessionName, "spaces-session")
        XCTAssertEqual(window?.isActive, true)
        XCTAssertEqual(window?.panePID, 4242)
    }
}
