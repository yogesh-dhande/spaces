#if canImport(AppKit) && canImport(Carbon) && canImport(GhosttyKit)
    import Carbon
    import Foundation
    import GhosttyKit
    import spacesterminalcore

    /// Turns a client-named key press into the libghostty key event a surface accepts, so the daemon's
    /// ghostty surface encodes it exactly as the Ghostty app would: Kitty keyboard protocol when the
    /// running program asked for it, DECCKM-aware arrows, legacy sequences otherwise.
    enum GhosttyEmbeddedKeyEvent {
        /// Keycodes are matched against ghostty's native-keycode table, and `0` is a real macOS keycode
        /// (the `A` key). A key we cannot name physically must therefore use a value that matches no
        /// entry, so ghostty resolves it to `unidentified` instead of silently becoming `A`.
        private static let unidentifiedKeycode: UInt32 = 0xFFFF

        /// Builds the event and passes it to `body`. The event borrows a C string for its `text` field,
        /// so it is only valid for the duration of the call.
        static func withKeyEvent<Result>(for spec: TerminalKeySpec, _ body: (ghostty_input_key_s) -> Result) -> Result {
            var event = ghostty_input_key_s()
            event.action = GHOSTTY_ACTION_PRESS
            event.mods = mods(for: spec.modifiers)
            event.consumed_mods = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
            event.keycode = keycode(for: spec.key)
            event.composing = false

            switch spec.key {
            case .character(let character):
                // Ghostty derives a ctrl chord's control byte from the typed text, and its Kitty CSI-u
                // code from the unshifted codepoint, so a character key must carry both. The text is
                // what the key would actually type: uppercase when shift is held, which is also what
                // keeps `ctrl+shift+c` distinguishable from `ctrl+c`.
                event.unshifted_codepoint = character.unicodeScalars.first?.value ?? 0
                let text = spec.modifiers.contains(.shift) ? String(character).uppercased() : String(character)
                return text.withCString { pointer in
                    event.text = pointer
                    return body(event)
                }
            default:
                // Named keys must carry no text. Ghostty treats text on enter/escape/backspace as
                // committed IME output and skips the functional-key encoding entirely, which would turn
                // Shift+Enter back into a bare newline.
                event.text = nil
                event.unshifted_codepoint = 0
                return body(event)
            }
        }

        private static func mods(for modifiers: TerminalKeyModifiers) -> ghostty_input_mods_e {
            var raw = GHOSTTY_MODS_NONE.rawValue
            if modifiers.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
            if modifiers.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
            if modifiers.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
            if modifiers.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
            return ghostty_input_mods_e(raw)
        }

        private static func keycode(for key: TerminalKey) -> UInt32 {
            switch key {
            case .enter: return UInt32(kVK_Return)
            case .tab: return UInt32(kVK_Tab)
            case .backspace: return UInt32(kVK_Delete)
            case .escape: return UInt32(kVK_Escape)
            case .up: return UInt32(kVK_UpArrow)
            case .down: return UInt32(kVK_DownArrow)
            case .left: return UInt32(kVK_LeftArrow)
            case .right: return UInt32(kVK_RightArrow)
            case .home: return UInt32(kVK_Home)
            case .end: return UInt32(kVK_End)
            case .pageUp: return UInt32(kVK_PageUp)
            case .pageDown: return UInt32(kVK_PageDown)
            case .forwardDelete: return UInt32(kVK_ForwardDelete)
            case .insert: return UInt32(kVK_Help)
            case .function(let number): return functionKeycodes[number] ?? unidentifiedKeycode
            case .character(let character): return characterKeycodes[Character(character.lowercased())] ?? unidentifiedKeycode
            }
        }

        private static let functionKeycodes: [Int: UInt32] = [
            1: UInt32(kVK_F1), 2: UInt32(kVK_F2), 3: UInt32(kVK_F3), 4: UInt32(kVK_F4), 5: UInt32(kVK_F5), 6: UInt32(kVK_F6),
            7: UInt32(kVK_F7), 8: UInt32(kVK_F8), 9: UInt32(kVK_F9), 10: UInt32(kVK_F10), 11: UInt32(kVK_F11), 12: UInt32(kVK_F12),
        ]

        /// The physical key a character sits on, used only for ghostty's keybinding lookup — the encoding
        /// itself comes from the event's text and unshifted codepoint. Characters outside this table
        /// resolve to `unidentified`, which still encodes correctly.
        private static let characterKeycodes: [Character: UInt32] = [
            "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D),
            "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F), "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H),
            "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
            "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O), "p": UInt32(kVK_ANSI_P),
            "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R), "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
            "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
            "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
            "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
            "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
            "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
        ]
    }
#endif
