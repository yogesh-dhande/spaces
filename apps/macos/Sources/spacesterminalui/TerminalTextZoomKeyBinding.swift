import AppKit
import Carbon
import spacesterminalcore

/// The fixed key combinations that zoom terminal text. Not user-configurable and not carried in any
/// settings row, so the mapping is stated once, here, as a pure function the pane's key routing and
/// its tests both read.
public enum TerminalTextZoomKeyBinding {
    /// The zoom step `keyCode` and `modifierFlags` express, or nil when the chord is not a zoom key.
    ///
    /// Cmd+Shift+= zooms in alongside Cmd+=: `=` and `+` are one key, so a user reaching for "Cmd
    /// plus" holds shift and means the same thing.
    public static func command(keyCode: Int, modifierFlags: NSEvent.ModifierFlags) -> TerminalTextZoomCommand? {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
        switch (keyCode, flags) {
        case (kVK_ANSI_Equal, [.command]), (kVK_ANSI_Equal, [.command, .shift]): return .zoomIn
        case (kVK_ANSI_Minus, [.command]): return .zoomOut
        default: return nil
        }
    }
}
