import Carbon
import XCTest

@testable import workspacecore

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

    func testParseModifierSetNormalizesLeaderModifiers() throws {
        let modifiers = try HotkeySpec.parseModifierSet("control option command")
        XCTAssertEqual(modifiers, [.cmd, .alt, .ctrl])
        XCTAssertEqual(HotkeySpec.normalizedModifierSet(modifiers), "cmd+alt+ctrl")
    }

    func testParseModifierSetRejectsNonModifierToken() {
        XCTAssertThrowsError(try HotkeySpec.parseModifierSet("cmd+k")) { error in
            XCTAssertEqual(error.localizedDescription, "Hotkey leader must contain only modifiers: k")
        }
    }

    func testParseModifierSetRejectsSingleModifierLeader() {
        XCTAssertThrowsError(try HotkeySpec.parseModifierSet("control")) { error in
            XCTAssertEqual(error.localizedDescription, "Hotkey leader must contain at least two modifiers")
        }
    }

    func testParseSupportsPunctuationKeys() throws {
        let spec = try HotkeySpec.parse("cmd+shift+=")
        XCTAssertEqual(spec.key, "=")
        XCTAssertEqual(spec.normalized, "cmd+shift+=")
    }

    func testParseRejectsMissingKey() {
        XCTAssertThrowsError(try HotkeySpec.parse("cmd+shift")) { error in XCTAssertEqual(error.localizedDescription, "Hotkey is missing a key") }
    }

    func testParseRejectsMultipleKeys() {
        XCTAssertThrowsError(try HotkeySpec.parse("cmd+a+b")) { error in
            XCTAssertEqual(error.localizedDescription, "Hotkey has multiple keys: a and b")
        }
    }

    func testParseRejectsEmptyValue() {
        XCTAssertThrowsError(try HotkeySpec.parse("  \n")) { error in XCTAssertEqual(error.localizedDescription, "Hotkey cannot be empty") }
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
        XCTAssertThrowsError(try HotkeySpec.parse("cmd+volumeup")) { error in XCTAssertEqual(error.localizedDescription, "Unsupported key: volumeup")
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

    func testParseSupportsNamedPunctuationAliases() throws {
        XCTAssertEqual(try HotkeySpec.parse("cmd minus").key, "minus")
        XCTAssertEqual(try HotkeySpec.parse("cmd dash").key, "minus")
        XCTAssertEqual(try HotkeySpec.parse("cmd equals").key, "=")
        XCTAssertEqual(try HotkeySpec.parse("cmd equal").key, "=")
        XCTAssertEqual(try HotkeySpec.parse("cmd backslash").key, "\\")
        XCTAssertEqual(try HotkeySpec.parse("cmd slash").key, "/")
        XCTAssertEqual(try HotkeySpec.parse("cmd comma").key, ",")
        XCTAssertEqual(try HotkeySpec.parse("cmd period").key, ".")
        XCTAssertEqual(try HotkeySpec.parse("cmd dot").key, ".")
        XCTAssertEqual(try HotkeySpec.parse("cmd quote").key, "'")
        XCTAssertEqual(try HotkeySpec.parse("cmd apostrophe").key, "'")
        XCTAssertEqual(try HotkeySpec.parse("cmd semicolon").key, ";")
        XCTAssertEqual(try HotkeySpec.parse("cmd leftbracket").key, "[")
        XCTAssertEqual(try HotkeySpec.parse("cmd lbracket").key, "[")
        XCTAssertEqual(try HotkeySpec.parse("cmd rightbracket").key, "]")
        XCTAssertEqual(try HotkeySpec.parse("cmd rbracket").key, "]")
        XCTAssertEqual(try HotkeySpec.parse("cmd grave").key, "`")
        XCTAssertEqual(try HotkeySpec.parse("cmd backtick").key, "`")
    }

    func testParseSupportsEnterAndBackspaceAliases() throws {
        XCTAssertEqual(try HotkeySpec.parse("cmd return").key, "return")
        XCTAssertEqual(try HotkeySpec.parse("cmd enter").key, "enter")
        XCTAssertEqual(try HotkeySpec.parse("cmd del").key, "delete")
        XCTAssertEqual(try HotkeySpec.parse("cmd backspace").key, "backspace")
        XCTAssertEqual(try HotkeySpec.parse("cmd forwarddelete").key, "forwarddelete")
        XCTAssertEqual(try HotkeySpec.parse("cmd right").key, "right")
        XCTAssertEqual(try HotkeySpec.parse("cmd up").key, "up")
        XCTAssertEqual(try HotkeySpec.parse("cmd down").key, "down")
    }

    func testParseSupportsDigitKeys() throws {
        XCTAssertEqual(try HotkeySpec.parse("cmd 0").key, "0")
        XCTAssertEqual(try HotkeySpec.parse("cmd 9").key, "9")
    }

    func testParseSupportsFunctionKeys() throws {
        XCTAssertEqual(try HotkeySpec.parse("cmd f1").key, "f1")
        XCTAssertEqual(try HotkeySpec.parse("cmd f12").key, "f12")
        XCTAssertEqual(try HotkeySpec.parse("cmd f20").key, "f20")
        XCTAssertThrowsError(try HotkeySpec.parse("cmd f21")) { error in XCTAssertEqual(error.localizedDescription, "Unsupported key: f21") }
        XCTAssertThrowsError(try HotkeySpec.parse("cmd f0")) { error in XCTAssertEqual(error.localizedDescription, "Unsupported key: f0") }
    }

    func testModifiersCarbonIncludesAltAndCtrl() throws {
        let altOnly = try HotkeySpec.parse("alt+a")
        XCTAssertEqual(altOnly.modifiersCarbon, UInt32(optionKey))

        let ctrlOnly = try HotkeySpec.parse("ctrl+a")
        XCTAssertEqual(ctrlOnly.modifiersCarbon, UInt32(controlKey))

        let allModifiers = try HotkeySpec.parse("cmd+shift+alt+ctrl+a")
        XCTAssertEqual(allModifiers.modifiersCarbon, UInt32(cmdKey | shiftKey | optionKey | controlKey))
    }

    func testKeyCodeForMappedKeys() throws {
        XCTAssertEqual(try HotkeySpec.parse("cmd+z").keyCode, UInt32(kVK_ANSI_Z))
        XCTAssertEqual(try HotkeySpec.parse("cmd+0").keyCode, UInt32(kVK_ANSI_0))
        XCTAssertEqual(try HotkeySpec.parse("cmd+9").keyCode, UInt32(kVK_ANSI_9))
        XCTAssertEqual(try HotkeySpec.parse("cmd+space").keyCode, UInt32(kVK_Space))
        XCTAssertEqual(try HotkeySpec.parse("cmd+tab").keyCode, UInt32(kVK_Tab))
        XCTAssertEqual(try HotkeySpec.parse("cmd+return").keyCode, UInt32(kVK_Return))
        XCTAssertEqual(try HotkeySpec.parse("cmd+escape").keyCode, UInt32(kVK_Escape))
        XCTAssertEqual(try HotkeySpec.parse("cmd+delete").keyCode, UInt32(kVK_Delete))
        XCTAssertEqual(try HotkeySpec.parse("cmd+forwarddelete").keyCode, UInt32(kVK_ForwardDelete))
        XCTAssertEqual(try HotkeySpec.parse("cmd+left").keyCode, UInt32(kVK_LeftArrow))
        XCTAssertEqual(try HotkeySpec.parse("cmd+right").keyCode, UInt32(kVK_RightArrow))
        XCTAssertEqual(try HotkeySpec.parse("cmd+up").keyCode, UInt32(kVK_UpArrow))
        XCTAssertEqual(try HotkeySpec.parse("cmd+down").keyCode, UInt32(kVK_DownArrow))
        XCTAssertEqual(try HotkeySpec.parse("cmd+minus").keyCode, UInt32(kVK_ANSI_Minus))
        XCTAssertEqual(try HotkeySpec.parse("cmd+[").keyCode, UInt32(kVK_ANSI_LeftBracket))
        XCTAssertEqual(try HotkeySpec.parse("cmd+]").keyCode, UInt32(kVK_ANSI_RightBracket))
        XCTAssertEqual(try HotkeySpec.parse("cmd+;").keyCode, UInt32(kVK_ANSI_Semicolon))
        XCTAssertEqual(try HotkeySpec.parse("cmd+'").keyCode, UInt32(kVK_ANSI_Quote))
        XCTAssertEqual(try HotkeySpec.parse("cmd+,").keyCode, UInt32(kVK_ANSI_Comma))
        XCTAssertEqual(try HotkeySpec.parse("cmd+.").keyCode, UInt32(kVK_ANSI_Period))
        XCTAssertEqual(try HotkeySpec.parse("cmd+/").keyCode, UInt32(kVK_ANSI_Slash))
        XCTAssertEqual(try HotkeySpec.parse("cmd+\\").keyCode, UInt32(kVK_ANSI_Backslash))
        XCTAssertEqual(try HotkeySpec.parse("cmd+`").keyCode, UInt32(kVK_ANSI_Grave))
    }

    func testNormalizedWithNoModifiers() {
        let spec = HotkeySpec(key: "a", modifiers: [])
        XCTAssertEqual(spec.normalized, "a")
    }

    // Tests parse with "+" (all separators, no keys) hits guard !tokens.isEmpty else throw.
    func testParseAllSeparatorsThrowsEmptyHotkey() {
        // "+" is normalized to " " (all separators replaced), split yields empty tokens array.
        XCTAssertThrowsError(try HotkeySpec.parse("+")) { error in XCTAssertEqual(error.localizedDescription, "Hotkey cannot be empty") }
        // "-" has the same behavior.
        XCTAssertThrowsError(try HotkeySpec.parse("-")) { error in XCTAssertEqual(error.localizedDescription, "Hotkey cannot be empty") }
    }

    // Tests parse with a 1-char unsupported punctuation throws (covers canonicalKeyName 1-char path that falls through to switch default).
    func testParseSingleUnsupportedPunctuationThrows() {
        // "!" is 1 char, not a letter/digit/allowed-punctuation and not a named key.
        XCTAssertThrowsError(try HotkeySpec.parse("cmd+!")) { error in XCTAssertEqual(error.localizedDescription, "Unsupported key: !") }
    }
}
