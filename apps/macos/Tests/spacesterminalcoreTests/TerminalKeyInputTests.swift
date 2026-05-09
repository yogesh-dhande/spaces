import XCTest

@testable import spacesterminalcore

final class TerminalKeyInputTests: XCTestCase {
    func testNamedKeysEncodeExpectedBytes() {
        XCTAssertEqual(TerminalKeyInput.bytes(for: "enter"), [0x0D])
        XCTAssertEqual(TerminalKeyInput.bytes(for: "esc"), [0x1B])
        XCTAssertEqual(TerminalKeyInput.bytes(for: "up"), Array("\u{1B}[A".utf8))
    }

    func testCtrlChordEncodesControlByte() {
        XCTAssertEqual(TerminalKeyInput.bytes(for: "ctrl+c"), [0x03])
        XCTAssertEqual(TerminalKeyInput.bytes(for: "ctrl-z"), [0x1A])
    }

    func testUnsupportedKeyReturnsNil() {
        XCTAssertNil(TerminalKeyInput.bytes(for: ""))
        XCTAssertNil(TerminalKeyInput.bytes(for: "ctrl+1"))
        XCTAssertNil(TerminalKeyInput.bytes(for: "f13"))
    }
}
