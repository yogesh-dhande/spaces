import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalQueryResponderTests: XCTestCase {
    private func fixture(named name: String) throws -> Data {
        let fixturesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "Fixtures", isDirectory: true)
        return try Data(contentsOf: fixturesRoot.appendingPathComponent(name))
    }

    func testResponderAnswersCodexStartupQueries() throws {
        var responder = TerminalQueryResponder()

        let responses = responder.responses(for: try fixture(named: "codex_startup_120x40.ansi"))

        XCTAssertEqual(
            responses,
            [
                Data("\u{001B}[1;1R".utf8), Data("\u{001B}[?62;4;22c".utf8), Data("\u{001B}]10;rgb:dddd/dddd/dddd\u{001B}\\".utf8),
                Data("\u{001B}]11;rgb:1111/1111/1111\u{001B}\\".utf8),
            ])
    }

    func testResponderHandlesQueriesSplitAcrossChunks() {
        var responder = TerminalQueryResponder()

        let firstResponses = responder.responses(for: Data("\u{001B}[6".utf8))
        let secondResponses = responder.responses(for: Data("n\u{001B}[c".utf8))

        XCTAssertTrue(firstResponses.isEmpty)
        XCTAssertEqual(secondResponses, [Data("\u{001B}[1;1R".utf8), Data("\u{001B}[?62;4;22c".utf8)])
    }

    func testResponderAnswersStatusAndSecondaryDeviceAttributesQueries() {
        var responder = TerminalQueryResponder()

        let responses = responder.responses(for: Data("\u{001B}[5n\u{001B}[>c".utf8))

        XCTAssertEqual(responses, [Data("\u{001B}[0n".utf8), Data("\u{001B}[>0;10;1c".utf8)])
    }

    func testResponderAnswersPrivateModeReportsUsingObservedModeState() {
        var responder = TerminalQueryResponder()

        let responses = responder.responses(for: Data("\u{001B}[?1004h\u{001B}[?1004$p\u{001B}[?2004$p\u{001B}[?9999$p".utf8))

        XCTAssertEqual(responses, [Data("\u{001B}[?1004;1$y".utf8), Data("\u{001B}[?2004;2$y".utf8), Data("\u{001B}[?9999;0$y".utf8)])
    }

    func testResponderAnswersPaletteColorQueriesForBothTerminators() {
        var responder = TerminalQueryResponder()

        let responses = responder.responses(for: Data("\u{001B}]4;2;?\u{0007}\u{001B}]4;196;?\u{001B}\\".utf8))

        XCTAssertEqual(responses, [Data("\u{001B}]4;2;rgb:0000/cdcd/0000\u{0007}".utf8), Data("\u{001B}]4;196;rgb:ffff/0000/0000\u{001B}\\".utf8)])
    }
}
