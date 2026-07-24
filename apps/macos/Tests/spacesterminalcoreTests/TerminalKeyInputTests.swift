import XCTest

@testable import spacesterminalcore

final class TerminalKeyInputTests: XCTestCase {
    private func keyPress(_ spec: String) -> TerminalKeySpec? {
        guard case .keyPress(let keySpec) = TerminalKeyInput.resolve(spec) else { return nil }
        return keySpec
    }

    private func lineEditingBytes(_ spec: String) -> [UInt8]? {
        guard case .lineEditingBytes(let bytes) = TerminalKeyInput.resolve(spec) else { return nil }
        return bytes
    }

    func testNamedKeysResolveToUnmodifiedKeyPresses() {
        XCTAssertEqual(keyPress("enter"), TerminalKeySpec(key: .enter))
        XCTAssertEqual(keyPress("return"), TerminalKeySpec(key: .enter))
        XCTAssertEqual(keyPress("esc"), TerminalKeySpec(key: .escape))
        XCTAssertEqual(keyPress("up"), TerminalKeySpec(key: .up))
        XCTAssertEqual(keyPress("home"), TerminalKeySpec(key: .home))
        XCTAssertEqual(keyPress("pagedown"), TerminalKeySpec(key: .pageDown))
        XCTAssertEqual(keyPress("forwarddelete"), TerminalKeySpec(key: .forwardDelete))
        XCTAssertEqual(keyPress("insert"), TerminalKeySpec(key: .insert))
        XCTAssertEqual(keyPress("f1"), TerminalKeySpec(key: .function(1)))
        XCTAssertEqual(keyPress("f12"), TerminalKeySpec(key: .function(12)))
    }

    func testModifiedKeysKeepTheirModifiers() {
        XCTAssertEqual(keyPress("shift+enter"), TerminalKeySpec(key: .enter, modifiers: [.shift]))
        XCTAssertEqual(keyPress("ctrl+enter"), TerminalKeySpec(key: .enter, modifiers: [.control]))
        XCTAssertEqual(keyPress("shift+tab"), TerminalKeySpec(key: .tab, modifiers: [.shift]))
        XCTAssertEqual(keyPress("shift+left"), TerminalKeySpec(key: .left, modifiers: [.shift]))
        XCTAssertEqual(keyPress("ctrl+c"), TerminalKeySpec(key: .character("c"), modifiers: [.control]))
    }

    func testModifierOrderAndSeparatorDoNotMatter() {
        let expected = TerminalKeySpec(key: .left, modifiers: [.control, .shift])
        XCTAssertEqual(keyPress("ctrl+shift+left"), expected)
        XCTAssertEqual(keyPress("shift+ctrl+left"), expected)
        XCTAssertEqual(keyPress("shift-ctrl-left"), expected)
        XCTAssertEqual(keyPress("SHIFT+Ctrl+Left"), expected)
        XCTAssertEqual(keyPress("control+z"), TerminalKeySpec(key: .character("z"), modifiers: [.control]))
    }

    /// These chords map a Mac editing convention onto readline and must stay fixed byte sequences, so
    /// they resolve ahead of key-press encoding rather than through it.
    func testMacLineEditingChordsResolveToFixedBytes() {
        XCTAssertEqual(lineEditingBytes("cmd+left"), [0x01])
        XCTAssertEqual(lineEditingBytes("command+right"), [0x05])
        XCTAssertEqual(lineEditingBytes("cmd+backspace"), [0x15])
        XCTAssertEqual(lineEditingBytes("opt+left"), Array("\u{1B}b".utf8))
        XCTAssertEqual(lineEditingBytes("option+right"), Array("\u{1B}f".utf8))
        XCTAssertEqual(lineEditingBytes("alt+backspace"), [0x17])
        XCTAssertEqual(lineEditingBytes("opt+b"), Array("\u{1B}b".utf8))
    }

    func testCommandKIsHostClearScreenAction() {
        XCTAssertEqual(TerminalKeyInput.resolve("cmd+k"), .hostAction(.clearScreenAndScrollback))
        XCTAssertEqual(TerminalKeyInput.hostAction(for: "command-k"), .clearScreenAndScrollback)
        XCTAssertTrue(TerminalKeyInput.isSupportedSpec("cmd+k"))
    }

    func testUnsupportedSpecsResolveToNothing() {
        XCTAssertNil(TerminalKeyInput.resolve(""))
        XCTAssertNil(TerminalKeyInput.resolve("f13"))
        XCTAssertNil(TerminalKeyInput.resolve("hyper+enter"))
        XCTAssertNil(TerminalKeyInput.resolve("shift+shift+enter"))
        // Command shortcuts that are not line-editing chords belong to the app, not the terminal.
        XCTAssertNil(TerminalKeyInput.resolve("cmd+z"))
        XCTAssertNil(TerminalKeyInput.resolve("cmd+up"))
    }
}
