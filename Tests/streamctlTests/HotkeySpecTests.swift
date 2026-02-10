import XCTest
@testable import streamctl

final class HotkeySpecTests: XCTestCase {
    func testParseNormalizesModifiers() throws {
        let spec = try HotkeySpec.parse("shift cmd A")
        XCTAssertEqual(spec.key, "a")
        XCTAssertEqual(spec.modifiers, [.cmd, .shift])
        XCTAssertEqual(spec.normalized, "cmd+shift+a")
    }

    func testParseSupportsNamedKeys() throws {
        let spec = try HotkeySpec.parse("option-ctrl-f5")
        XCTAssertEqual(spec.key, "f5")
        XCTAssertEqual(spec.modifiers, [.alt, .ctrl])
        XCTAssertEqual(spec.normalized, "alt+ctrl+f5")
    }

    func testParseSupportsPunctuationKeys() throws {
        let spec = try HotkeySpec.parse("cmd+shift+=")
        XCTAssertEqual(spec.key, "=")
        XCTAssertEqual(spec.normalized, "cmd+shift+=")
    }

    func testParseRejectsMissingKey() {
        XCTAssertThrowsError(try HotkeySpec.parse("cmd+shift")) { error in
            XCTAssertEqual(error.localizedDescription, "Hotkey is missing a key")
        }
    }

    func testParseRejectsMultipleKeys() {
        XCTAssertThrowsError(try HotkeySpec.parse("cmd+a+b")) { error in
            XCTAssertEqual(error.localizedDescription, "Hotkey has multiple keys: a and b")
        }
    }

    func testParseRejectsEmptyValue() {
        XCTAssertThrowsError(try HotkeySpec.parse("  \n")) { error in
            XCTAssertEqual(error.localizedDescription, "Hotkey cannot be empty")
        }
    }
}
