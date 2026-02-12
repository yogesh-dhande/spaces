import Carbon
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

    func testParseSupportsModifierAliasesAndNamedKeys() throws {
        let spec = try HotkeySpec.parse("command option control shift spacebar")
        XCTAssertEqual(spec.key, "space")
        XCTAssertEqual(spec.modifiers, [.cmd, .shift, .alt, .ctrl])
        XCTAssertEqual(spec.normalized, "cmd+shift+alt+ctrl+space")
    }

    func testParseSupportsDirectionalAndDeleteAliases() throws {
        XCTAssertEqual(try HotkeySpec.parse("ctrl-left").key, "left")
        XCTAssertEqual(try HotkeySpec.parse("alt forwarddelete").key, "forwarddelete")
        XCTAssertEqual(try HotkeySpec.parse("cmd-esc").key, "escape")
    }

    func testParseRejectsUnsupportedKey() {
        XCTAssertThrowsError(try HotkeySpec.parse("cmd+volumeup")) { error in
            XCTAssertEqual(error.localizedDescription, "Unsupported key: volumeup")
        }
    }

    func testKeyCodeAndModifierFlags() throws {
        let spec = try HotkeySpec.parse("cmd+shift+a")
        XCTAssertEqual(spec.keyCode, UInt32(kVK_ANSI_A))
        XCTAssertEqual(spec.modifiersCarbon, UInt32(cmdKey | shiftKey))
    }

    func testUnknownKeyCodeFallsBackToAAndNormalizedWithoutModifiers() {
        let spec = HotkeySpec(key: "unknown", modifiers: [])
        XCTAssertEqual(spec.keyCode, UInt32(kVK_ANSI_A))
        XCTAssertEqual(spec.normalized, "unknown")
    }
}
