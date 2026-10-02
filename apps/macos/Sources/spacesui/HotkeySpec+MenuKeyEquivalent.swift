import AppKit
import workspacecore

extension HotkeySpec {
    /// The `NSMenuItem` key equivalent for this chord, or nil for a key with no single-character form
    /// (arrows, return, named punctuation).
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard key.count == 1 else { return nil }
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.cmd) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.alt) { mask.insert(.option) }
        if modifiers.contains(.ctrl) { mask.insert(.control) }
        return (key, mask)
    }
}
