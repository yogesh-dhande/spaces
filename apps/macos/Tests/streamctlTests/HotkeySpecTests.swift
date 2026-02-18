import Carbon
import XCTest

@testable import streamctl

final class HotkeySpecTests: XCTestCase {
    // Tests parse normalizes modifiers by arranging representative inputs and asserting the expected result.
    func testParseNormalizesModifiers() throws {
        let spec = try HotkeySpec.parse("shift cmd A")
        XCTAssertEqual(spec.key, "a")
        XCTAssertEqual(spec.modifiers, [.cmd, .shift])
        XCTAssertEqual(spec.normalized, "cmd+shift+a")
    }

    // Tests parse supports named keys by arranging representative inputs and asserting the expected result.
    func testParseSupportsNamedKeys() throws {
        let spec = try HotkeySpec.parse("option-ctrl-f5")
        XCTAssertEqual(spec.key, "f5")
        XCTAssertEqual(spec.modifiers, [.alt, .ctrl])
        XCTAssertEqual(spec.normalized, "alt+ctrl+f5")
    }

    // Tests parse supports punctuation keys by arranging representative inputs and asserting the expected result.
    func testParseSupportsPunctuationKeys() throws {
        let spec = try HotkeySpec.parse("cmd+shift+=")
        XCTAssertEqual(spec.key, "=")
        XCTAssertEqual(spec.normalized, "cmd+shift+=")
    }

    // Tests parse rejects missing key by arranging representative inputs and asserting the expected result.
    func testParseRejectsMissingKey() {
        XCTAssertThrowsError(try HotkeySpec.parse("cmd+shift")) { error in XCTAssertEqual(error.localizedDescription, "Hotkey is missing a key") }
    }

    // Tests parse rejects multiple keys by arranging representative inputs and asserting the expected result.
    func testParseRejectsMultipleKeys() {
        XCTAssertThrowsError(try HotkeySpec.parse("cmd+a+b")) { error in
            XCTAssertEqual(error.localizedDescription, "Hotkey has multiple keys: a and b")
        }
    }

    // Tests parse rejects empty value by arranging representative inputs and asserting the expected result.
    func testParseRejectsEmptyValue() {
        XCTAssertThrowsError(try HotkeySpec.parse("  \n")) { error in XCTAssertEqual(error.localizedDescription, "Hotkey cannot be empty") }
    }

    // Tests parse supports modifier aliases and named keys by arranging representative inputs and asserting the expected result.
    func testParseSupportsModifierAliasesAndNamedKeys() throws {
        let spec = try HotkeySpec.parse("command option control shift spacebar")
        XCTAssertEqual(spec.key, "space")
        XCTAssertEqual(spec.modifiers, [.cmd, .shift, .alt, .ctrl])
        XCTAssertEqual(spec.normalized, "cmd+shift+alt+ctrl+space")
    }

    // Tests parse supports directional and delete aliases by arranging representative inputs and asserting the expected result.
    func testParseSupportsDirectionalAndDeleteAliases() throws {
        XCTAssertEqual(try HotkeySpec.parse("ctrl-left").key, "left")
        XCTAssertEqual(try HotkeySpec.parse("alt forwarddelete").key, "forwarddelete")
        XCTAssertEqual(try HotkeySpec.parse("cmd-esc").key, "escape")
    }

    // Tests parse rejects unsupported key by arranging representative inputs and asserting the expected result.
    func testParseRejectsUnsupportedKey() {
        XCTAssertThrowsError(try HotkeySpec.parse("cmd+volumeup")) { error in XCTAssertEqual(error.localizedDescription, "Unsupported key: volumeup")
        }
    }

    // Tests key code and modifier flags by arranging representative inputs and asserting the expected result.
    func testKeyCodeAndModifierFlags() throws {
        let spec = try HotkeySpec.parse("cmd+shift+a")
        XCTAssertEqual(spec.keyCode, UInt32(kVK_ANSI_A))
        XCTAssertEqual(spec.modifiersCarbon, UInt32(cmdKey | shiftKey))
    }

    // Tests unknown key code falls back to a and normalized without modifiers by arranging representative inputs and asserting the expected result.
    func testUnknownKeyCodeFallsBackToAAndNormalizedWithoutModifiers() {
        let spec = HotkeySpec(key: "unknown", modifiers: [])
        XCTAssertEqual(spec.keyCode, UInt32(kVK_ANSI_A))
        XCTAssertEqual(spec.normalized, "unknown")
    }
}
