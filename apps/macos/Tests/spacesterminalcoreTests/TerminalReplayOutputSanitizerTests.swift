import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalReplayOutputSanitizerTests: XCTestCase {
    func testStripsPromptEndOfLineMarkArtifacts() {
        let output = Data(
            """
            first\r
            \u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m      \r \r\r\u{1B}[0m\u{1B}[27m\u{1B}[24m\u{1B}[Jprompt % second\r

            """.utf8)

        let sanitized = TerminalReplayOutputSanitizer.renderableOutputData(from: output)
        let text = String(decoding: sanitized, as: UTF8.self)

        XCTAssertFalse(text.contains("\u{1B}[7m%"))
        XCTAssertFalse(text.contains("\n%"))
        XCTAssertTrue(text.contains("first\r\n"))
        XCTAssertTrue(text.contains("prompt % second\r\n"))
    }

    func testStripsPromptEndOfLineMarkArtifactsBeforeShellIntegrationSequences() {
        let output = Data(
            "first\r\n\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m      \r \r\u{1B}]133;D;0\u{7}\u{1B}]7;file://cwd\u{7}\r\u{1B}[0m\u{1B}[Jprompt % second\r\n"
                .utf8)

        let sanitized = TerminalReplayOutputSanitizer.renderableOutputData(from: output)
        let text = String(decoding: sanitized, as: UTF8.self)

        XCTAssertFalse(text.contains("\u{1B}[7m%"))
        XCTAssertFalse(text.contains("\n%"))
        XCTAssertTrue(text.contains("first\r\n"))
        XCTAssertTrue(text.contains("prompt % second\r\n"))
    }

    func testNormalizesBareLineFeeds() {
        let output = Data("one\ntwo\r\nthree".utf8)

        let sanitized = TerminalReplayOutputSanitizer.renderableOutputData(from: output)

        XCTAssertEqual(String(decoding: sanitized, as: UTF8.self), "one\r\ntwo\r\nthree")
    }
}
