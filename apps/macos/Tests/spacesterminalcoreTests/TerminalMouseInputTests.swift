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

    func testSGRMouseSequenceEncodesModifiersAndMoveButtons() {
        XCTAssertEqual(
            TerminalMouseInput.sgrSequence(action: .move, button: .right, column: 9, row: 7, shift: true, option: true, control: true),
            "\u{001B}[<62;9;7M")
        XCTAssertEqual(TerminalMouseInput.sgrSequence(action: .move, button: .none, column: 5, row: 2), "\u{001B}[<35;5;2M")
        XCTAssertEqual(TerminalMouseInput.sgrSequence(action: .press, button: .middle, column: 4, row: 6), "\u{001B}[<1;4;6M")
    }

    func testX10MouseSequenceEncodesClassicXtermCoordinates() {
        XCTAssertEqual(TerminalMouseInput.x10Sequence(action: .press, button: .left, column: 8, row: 3), "\u{001B}[M (#")
        XCTAssertEqual(TerminalMouseInput.x10Sequence(action: .scrollDown, button: .none, column: 8, row: 3), "\u{001B}[Ma(#")
        XCTAssertEqual(
            TerminalMouseInput.x10Sequence(action: .move, button: .right, column: 9, row: 7, shift: true, option: true, control: true),
            "\u{001B}[M^)'")
    }
}
