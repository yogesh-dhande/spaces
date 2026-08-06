import AppKit
import Carbon
import spacesterminalcore

/// The fixed key combinations that zoom terminal text. Not user-configurable and not carried in any
/// settings row, so the mapping is stated once, here, as a pure function the pane's key routing and
/// its tests both read.
public enum TerminalTextZoomKeyBinding {
    /// The zoom step `keyCode` and `modifierFlags` express, or nil when the chord is not a zoom key.
    ///
    /// Shift is accepted on both keys. `=` and `+` are one key, so a user reaching for "Cmd plus"
    /// holds shift and means zoom in; shift on the minus key means nothing else here, and holding it
    /// across both keys is what a user coming from a browser expects.
    ///
    /// Caps lock, the function bit, and the numeric-pad bit are dropped before matching: they describe
    /// the keyboard's state rather than a modifier the user is holding for this chord, and a chord
    /// matched exactly would otherwise stop zooming for as long as caps lock is on.
    public static func command(keyCode: Int, modifierFlags: NSEvent.ModifierFlags) -> TerminalTextZoomCommand? {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad])
        switch (keyCode, flags) {
        case (kVK_ANSI_Equal, [.command]), (kVK_ANSI_Equal, [.command, .shift]): return .zoomIn
        case (kVK_ANSI_Minus, [.command]), (kVK_ANSI_Minus, [.command, .shift]): return .zoomOut
        default: return nil
        }
    }
}
