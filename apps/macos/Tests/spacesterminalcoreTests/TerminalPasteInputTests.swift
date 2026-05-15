import XCTest

@testable import spacesterminalcore

final class TerminalPasteInputTests: XCTestCase {
    func testWrappedReturnsOriginalTextWhenBracketedPasteIsDisabled() {
        XCTAssertEqual(TerminalPasteInput.wrapped("hello", usesBracketedPasteMode: false), "hello")
    }

    func testWrappedEnclosesTextInBracketedPasteMarkersWhenEnabled() {
        XCTAssertEqual(TerminalPasteInput.wrapped("hello", usesBracketedPasteMode: true), "\u{001B}[200~hello\u{001B}[201~")
    }
}
