import XCTest

@testable import spacesterminalcore

final class TerminalKeyInputTests: XCTestCase {
    func testNamedKeysEncodeExpectedBytes() {
        XCTAssertEqual(TerminalKeyInput.bytes(for: "enter"), [0x0D])
        XCTAssertEqual(TerminalKeyInput.bytes(for: "esc"), [0x1B])
        XCTAssertEqual(TerminalKeyInput.bytes(for: "up"), Array("\u{1B}[A".utf8))
        XCTAssertEqual(TerminalKeyInput.bytes(for: "home"), Array("\u{1B}[H".utf8))
        XCTAssertEqual(TerminalKeyInput.bytes(for: "end"), Array("\u{1B}[F".utf8))
        XCTAssertEqual(TerminalKeyInput.bytes(for: "pageup"), Array("\u{1B}[5~".utf8))
        XCTAssertEqual(TerminalKeyInput.bytes(for: "pagedown"), Array("\u{1B}[6~".utf8))
        XCTAssertEqual(TerminalKeyInput.bytes(for: "forwarddelete"), Array("\u{1B}[3~".utf8))
        XCTAssertEqual(TerminalKeyInput.bytes(for: "insert"), Array("\u{1B}[2~".utf8))
        XCTAssertEqual(TerminalKeyInput.bytes(for: "backtab"), Array("\u{1B}[Z".utf8))
    }

    func testFunctionKeysEncodeGhosttyTerminfoSequences() {
        XCTAssertEqual(TerminalKeyInput.bytes(for: "f1"), Array("\u{1B}OP".utf8))
        XCTAssertEqual(TerminalKeyInput.bytes(for: "f4"), Array("\u{1B}OS".utf8))
        XCTAssertEqual(TerminalKeyInput.bytes(for: "f5"), Array("\u{1B}[15~".utf8))
        XCTAssertEqual(TerminalKeyInput.bytes(for: "f10"), Array("\u{1B}[21~".utf8))
        XCTAssertEqual(TerminalKeyInput.bytes(for: "f12"), Array("\u{1B}[24~".utf8))
    }

    func testCtrlChordEncodesControlByte() {
        XCTAssertEqual(TerminalKeyInput.bytes(for: "ctrl+c"), [0x03])
        XCTAssertEqual(TerminalKeyInput.bytes(for: "ctrl+u"), [0x15])
        XCTAssertEqual(TerminalKeyInput.bytes(for: "ctrl+w"), [0x17])
        XCTAssertEqual(TerminalKeyInput.bytes(for: "ctrl-z"), [0x1A])
    }

    func testUnsupportedKeyReturnsNil() {
        XCTAssertNil(TerminalKeyInput.bytes(for: ""))
        XCTAssertNil(TerminalKeyInput.bytes(for: "ctrl+1"))
        XCTAssertNil(TerminalKeyInput.bytes(for: "f13"))
    }
}
