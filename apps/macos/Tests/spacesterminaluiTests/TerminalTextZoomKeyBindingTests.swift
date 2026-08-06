import AppKit
import Carbon
import Testing
import spacesterminalcore

@testable import spacesterminalui

/// The zoom keys are fixed, so the chord-to-step mapping is the whole contract.
@Suite struct TerminalTextZoomKeyBindingTests {
    @Test func commandEqualsAndCommandShiftEqualsBothZoomIn() {
        #expect(TerminalTextZoomKeyBinding.command(keyCode: kVK_ANSI_Equal, modifierFlags: [.command]) == .zoomIn)
        #expect(TerminalTextZoomKeyBinding.command(keyCode: kVK_ANSI_Equal, modifierFlags: [.command, .shift]) == .zoomIn)
    }

    @Test func commandMinusZoomsOut() {
        #expect(TerminalTextZoomKeyBinding.command(keyCode: kVK_ANSI_Minus, modifierFlags: [.command]) == .zoomOut)
    }

    /// `Cmd+0` is the numbered window shortcut for a workspace's tenth runtime target, not a zoom
    /// chord, so it must resolve to nil here: that is what leaves the window shortcut alone.
    @Test func commandZeroIsNotAZoomChord() {
        #expect(TerminalTextZoomKeyBinding.command(keyCode: kVK_ANSI_0, modifierFlags: [.command]) == nil)
    }

    /// Hardware modifiers the user is not holding (caps lock state, the numeric-pad and function bits
    /// a laptop keyboard sets on its own) must not stop a zoom key from being recognized.
    @Test func incidentalModifierBitsAreIgnored() {
        #expect(TerminalTextZoomKeyBinding.command(keyCode: kVK_ANSI_Minus, modifierFlags: [.command, .function, .numericPad]) == .zoomOut)
    }

    /// Chords that are not the zoom keys are left alone, so they keep reaching the terminal and the
    /// rest of the app: bare `-`, other modifier combinations, and the shifted forms of the keys that
    /// only zoom unshifted.
    @Test(arguments: [
        (kVK_ANSI_Equal, NSEvent.ModifierFlags([])), (kVK_ANSI_Minus, NSEvent.ModifierFlags([])),
        (kVK_ANSI_Minus, NSEvent.ModifierFlags([.command, .shift])), (kVK_ANSI_0, NSEvent.ModifierFlags([.command, .shift])),
        (kVK_ANSI_Equal, NSEvent.ModifierFlags([.command, .option])), (kVK_ANSI_Equal, NSEvent.ModifierFlags([.control])),
        (kVK_ANSI_C, NSEvent.ModifierFlags([.command])),
    ]) func nonZoomChordsAreNotClaimed(keyCode: Int, modifierFlags: NSEvent.ModifierFlags) {
        #expect(TerminalTextZoomKeyBinding.command(keyCode: keyCode, modifierFlags: modifierFlags) == nil)
    }
}
