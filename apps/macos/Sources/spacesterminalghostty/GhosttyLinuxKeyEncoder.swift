#if os(Linux)
    import Foundation
    import ghosttyvtshim
    import spacesterminalcore

    /// Encodes a client-named key press with libghostty-vt's key encoder, configured from the session's
    /// live terminal. This is the Linux counterpart of the macOS daemon handing the key to its ghostty
    /// surface: both run ghostty's own encoder, so a key press produces the same bytes on either host.
    enum GhosttyLinuxKeyEncoder {
        /// Returns the encoded bytes, or nil when the encoder call fails. A key that legitimately encodes
        /// to nothing returns empty data.
        static func encode(_ spec: TerminalKeySpec, session: OpaquePointer) -> Data? {
            var encodedPointer: UnsafeMutablePointer<CChar>?
            var encodedLength: size_t = 0
            let encoded = withKeyText(for: spec) { textPointer, textLength in
                spaces_ghostty_vt_session_encode_key(
                    session, shimKey(for: spec.key).rawValue, shimModifiers(for: spec.modifiers), textPointer, textLength,
                    unshiftedCodepoint(for: spec.key), &encodedPointer, &encodedLength)
            }
            guard encoded else { return nil }
            defer { if let encodedPointer { spaces_ghostty_vt_free_buffer(encodedPointer) } }
            guard let encodedPointer, encodedLength > 0 else { return Data() }
            return Data(bytes: encodedPointer, count: encodedLength)
        }

        /// Named keys must carry no text: ghostty treats text on enter/escape/backspace as committed IME
        /// output and skips functional-key encoding, which would turn Shift+Enter back into a newline.
        /// A character key carries what it would type, uppercased when shift is held, because that is
        /// what ghostty reads to build a ctrl chord's control byte.
        private static func withKeyText(for spec: TerminalKeySpec, _ body: (UnsafePointer<CChar>?, size_t) -> Bool) -> Bool {
            guard case .character(let character) = spec.key else { return body(nil, 0) }
            let text = spec.modifiers.contains(.shift) ? String(character).uppercased() : String(character)
            let length = text.utf8.count
            return text.withCString { pointer in body(pointer, length) }
        }

        private static func unshiftedCodepoint(for key: TerminalKey) -> UInt32 {
            guard case .character(let character) = key else { return 0 }
            return character.unicodeScalars.first?.value ?? 0
        }

        private static func shimModifiers(for modifiers: TerminalKeyModifiers) -> UInt16 {
            var raw = 0
            if modifiers.contains(.shift) { raw |= Int(SPACES_GHOSTTY_VT_MODS_SHIFT) }
            if modifiers.contains(.control) { raw |= Int(SPACES_GHOSTTY_VT_MODS_CTRL) }
            if modifiers.contains(.option) { raw |= Int(SPACES_GHOSTTY_VT_MODS_ALT) }
            if modifiers.contains(.command) { raw |= Int(SPACES_GHOSTTY_VT_MODS_SUPER) }
            return UInt16(raw)
        }

        /// Printable keys stay `unidentified`: the encoder reads their text and unshifted codepoint, not
        /// their physical key, and there is no keybinding lookup on this host to care about the rest.
        private static func shimKey(for key: TerminalKey) -> SpacesGhosttyVtKey {
            switch key {
            case .enter: return SPACES_GHOSTTY_VT_KEY_ENTER
            case .tab: return SPACES_GHOSTTY_VT_KEY_TAB
            case .backspace: return SPACES_GHOSTTY_VT_KEY_BACKSPACE
            case .escape: return SPACES_GHOSTTY_VT_KEY_ESCAPE
            case .up: return SPACES_GHOSTTY_VT_KEY_ARROW_UP
            case .down: return SPACES_GHOSTTY_VT_KEY_ARROW_DOWN
            case .left: return SPACES_GHOSTTY_VT_KEY_ARROW_LEFT
            case .right: return SPACES_GHOSTTY_VT_KEY_ARROW_RIGHT
            case .home: return SPACES_GHOSTTY_VT_KEY_HOME
            case .end: return SPACES_GHOSTTY_VT_KEY_END
            case .pageUp: return SPACES_GHOSTTY_VT_KEY_PAGE_UP
            case .pageDown: return SPACES_GHOSTTY_VT_KEY_PAGE_DOWN
            case .forwardDelete: return SPACES_GHOSTTY_VT_KEY_DELETE
            case .insert: return SPACES_GHOSTTY_VT_KEY_INSERT
            case .function(let number): return functionKeys[number] ?? SPACES_GHOSTTY_VT_KEY_UNIDENTIFIED
            case .character: return SPACES_GHOSTTY_VT_KEY_UNIDENTIFIED
            }
        }

        private static let functionKeys: [Int: SpacesGhosttyVtKey] = [
            1: SPACES_GHOSTTY_VT_KEY_F1, 2: SPACES_GHOSTTY_VT_KEY_F2, 3: SPACES_GHOSTTY_VT_KEY_F3, 4: SPACES_GHOSTTY_VT_KEY_F4,
            5: SPACES_GHOSTTY_VT_KEY_F5, 6: SPACES_GHOSTTY_VT_KEY_F6, 7: SPACES_GHOSTTY_VT_KEY_F7, 8: SPACES_GHOSTTY_VT_KEY_F8,
            9: SPACES_GHOSTTY_VT_KEY_F9, 10: SPACES_GHOSTTY_VT_KEY_F10, 11: SPACES_GHOSTTY_VT_KEY_F11, 12: SPACES_GHOSTTY_VT_KEY_F12,
        ]
    }
#endif
