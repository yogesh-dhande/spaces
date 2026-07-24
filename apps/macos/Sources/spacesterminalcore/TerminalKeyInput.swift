import Foundation

/// Resolves the key specs clients send (`"enter"`, `"shift+enter"`, `"ctrl+c"`, `"cmd+left"`) into
/// what the session host should do with them.
///
/// A spec names a key and its modifiers; it does not name bytes. Encoding lives at the session host
/// because the correct bytes depend on terminal state only the host has: Shift+Enter is a bare `\r`
/// in a plain shell but `CSI 13;2u` once an application enables the Kitty keyboard protocol, and
/// arrows switch between `CSI` and `SS3` forms with DECCKM. The host runs Ghostty's own key encoder
/// against the live terminal, so Spaces encodes exactly as Ghostty does.
///
/// Two kinds of spec are deliberately *not* key presses:
///
/// - `cmd+k` is an app action (clear screen and scrollback), not terminal input.
/// - The Mac line-editing chords are fixed byte sequences. They exist to map a macOS/iOS editing
///   convention onto readline (`cmd+left` means "beginning of line", so it sends `ctrl+a`), and that
///   mapping must not vary with terminal mode. Encoding them as Alt-modified key presses would also
///   break outright: Ghostty only emits an ESC prefix for Alt when DECSET 1036 is on *and*
///   `macos-option-as-alt` is enabled, so `opt+left` would silently produce nothing.
public enum TerminalKeyInput {
    public enum HostAction: Equatable, Sendable { case clearScreenAndScrollback }

    /// What a key spec means to the session host.
    public enum Resolution: Equatable, Sendable {
        /// An app action rather than terminal input.
        case hostAction(HostAction)
        /// A Mac line-editing chord, which is mode-independent by design.
        case lineEditingBytes([UInt8])
        /// A key press for the host to encode against the live terminal state.
        case keyPress(TerminalKeySpec)
    }

    public static func isSupportedSpec(_ spec: String) -> Bool { resolve(spec) != nil }

    public static func hostAction(for spec: String) -> HostAction? {
        guard case .hostAction(let action) = resolve(spec) else { return nil }
        return action
    }

    public static func resolve(_ spec: String) -> Resolution? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // Unmodified keys are matched whole so multi-word names such as `forwarddelete` are not
        // split apart by the modifier parsing below.
        if let key = TerminalKey(name: trimmed) { return .keyPress(TerminalKeySpec(key: key)) }

        let parts = trimmed.replacingOccurrences(of: "-", with: "+").split(separator: "+").map(String.init)
        guard parts.count >= 2, let key = TerminalKey(name: parts[parts.count - 1]) else { return nil }
        var modifiers: TerminalKeyModifiers = []
        for token in parts.dropLast() {
            guard let modifier = TerminalKeyModifiers(token: token), !modifiers.contains(modifier) else { return nil }
            modifiers.insert(modifier)
        }

        if modifiers == [.command], key == .character("k") { return .hostAction(.clearScreenAndScrollback) }
        if let bytes = lineEditingBytes(key: key, modifiers: modifiers) { return .lineEditingBytes(bytes) }
        // Command chords that are not line-editing chords belong to the app, not the terminal: there is
        // no useful encoding for Super-modified input, so they are rejected rather than sent.
        guard !modifiers.contains(.command) else { return nil }
        return .keyPress(TerminalKeySpec(key: key, modifiers: modifiers))
    }

    private static func lineEditingBytes(key: TerminalKey, modifiers: TerminalKeyModifiers) -> [UInt8]? {
        switch (modifiers, key) {
        case ([.command], .left): return [0x01]  // ctrl+a: beginning of line
        case ([.command], .right): return [0x05]  // ctrl+e: end of line
        case ([.command], .backspace): return [0x15]  // ctrl+u: delete to beginning of line
        case ([.option], .left): return Array("\u{1B}b".utf8)  // meta-b: back one word
        case ([.option], .right): return Array("\u{1B}f".utf8)  // meta-f: forward one word
        case ([.option], .backspace): return [0x17]  // ctrl+w: delete previous word
        // The iOS accessory's Option modifier composes meta chords with ordinary letters.
        case ([.option], .character(let character)): return [0x1B] + Array(String(character).utf8)
        default: return nil
        }
    }
}
