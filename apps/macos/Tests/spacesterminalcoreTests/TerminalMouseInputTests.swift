import XCTest

@testable import spacesterminalcore

final class TerminalMouseInputTests: XCTestCase {
    func testSGRScrollSequenceUsesWheelCodes() {
        XCTAssertEqual(TerminalMouseInput.sgrSequence(action: .scrollUp, button: .none, column: 12, row: 4), "\u{001B}[<64;12;4M")
        XCTAssertEqual(TerminalMouseInput.sgrSequence(action: .scrollDown, button: .none, column: 12, row: 4), "\u{001B}[<65;12;4M")
    }

    func testSGRReleaseSequenceUsesLowercaseTerminator() {
        XCTAssertEqual(TerminalMouseInput.sgrSequence(action: .release, button: .left, column: 2, row: 3), "\u{001B}[<0;2;3m")
    }
}
