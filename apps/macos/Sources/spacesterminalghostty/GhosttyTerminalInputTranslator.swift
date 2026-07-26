#if canImport(AppKit) && canImport(Carbon)
    import AppKit
    import Carbon
    import Foundation

    enum GhosttyTerminalInputTranslator {
        static func shouldDeferToSystemShortcut(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
            let flags = modifierFlags.intersection([.command, .shift, .option, .control, .function])
            let isPlainCommandShortcut = flags == .command
            if isPlainCommandShortcut {
                switch Int(keyCode) {
                case kVK_ANSI_W, kVK_ANSI_M, kVK_ANSI_H, kVK_ANSI_Q, kVK_ANSI_Comma: return true
                default: break
                }
            }

            let isWindowTilingShortcut =
                flags == [.control, .function]
                && (keyCode == UInt16(kVK_LeftArrow) || keyCode == UInt16(kVK_RightArrow) || keyCode == UInt16(kVK_UpArrow)
                    || keyCode == UInt16(kVK_DownArrow))
            return isWindowTilingShortcut
        }

        static func ghosttyText(for event: NSEvent) -> String? {
            guard let characters = event.characters else { return nil }
            guard characters.count == 1, let scalar = characters.unicodeScalars.first else { return characters }

            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }

            if isPrivateUseFunctionKeyScalar(scalar.value) { return nil }
            return characters
        }

        /// Names the key press for the session host to encode, or nil when the event is text rather than a
        /// named key (the caller then sends it through the text path).
        ///
        /// Modifiers are part of the name. Dropping them is what made Shift+Enter indistinguishable from
        /// Enter and left modified arrows producing nothing at all. The host resolves the name against
        /// live terminal state, so one spec still encodes differently under the Kitty keyboard protocol.
        static func keySpecifier(for event: NSEvent) -> String? {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keyCode = Int(event.keyCode)
            // Command chords are app shortcuts apart from the few Mac editing chords the terminal claims,
            // so they never take the general path below.
            if flags.contains(.command) { return commandChordSpecifier(keyCode: keyCode, flags: flags) }
            guard let name = namedKey(for: keyCode) ?? controlChordKey(for: event, flags: flags) else { return nil }
            return (modifierPrefixes(for: flags) + [name]).joined(separator: "+")
        }

        private static func modifierPrefixes(for flags: NSEvent.ModifierFlags) -> [String] {
            var prefixes: [String] = []
            if flags.contains(.control) { prefixes.append("ctrl") }
            if flags.contains(.shift) { prefixes.append("shift") }
            if flags.contains(.option) { prefixes.append("opt") }
            return prefixes
        }

        private static func namedKey(for keyCode: Int) -> String? {
            switch keyCode {
            case kVK_Return, kVK_ANSI_KeypadEnter: return "enter"
            case kVK_Tab: return "tab"
            case kVK_Delete: return "backspace"
            case kVK_Escape: return "esc"
            case kVK_UpArrow: return "up"
            case kVK_DownArrow: return "down"
            case kVK_LeftArrow: return "left"
            case kVK_RightArrow: return "right"
            case kVK_Home: return "home"
            case kVK_End: return "end"
            case kVK_PageUp: return "pageup"
            case kVK_PageDown: return "pagedown"
            case kVK_ForwardDelete: return "forwarddelete"
            case kVK_Help: return "insert"
            case kVK_F1: return "f1"
            case kVK_F2: return "f2"
            case kVK_F3: return "f3"
            case kVK_F4: return "f4"
            case kVK_F5: return "f5"
            case kVK_F6: return "f6"
            case kVK_F7: return "f7"
            case kVK_F8: return "f8"
            case kVK_F9: return "f9"
            case kVK_F10: return "f10"
            case kVK_F11: return "f11"
            case kVK_F12: return "f12"
            default: return nil
            }
        }

        /// The letter of a ctrl chord. Only letters are named; every other ctrl combination still reaches
        /// the terminal through the text path.
        private static func controlChordKey(for event: NSEvent, flags: NSEvent.ModifierFlags) -> String? {
            guard flags.contains(.control) else { return nil }
            guard let flaglessCharacters = event.charactersIgnoringModifiers, flaglessCharacters.count == 1,
                let scalar = flaglessCharacters.unicodeScalars.first, scalar.properties.isAlphabetic
            else { return nil }
            return String(scalar).lowercased()
        }

        /// The Mac editing conventions the terminal claims from Command: clear, and the line-editing
        /// chords. Anything else Command-modified stays an app shortcut.
        private static func commandChordSpecifier(keyCode: Int, flags: NSEvent.ModifierFlags) -> String? {
            guard flags.intersection([.command, .control, .option, .shift]) == [.command] else { return nil }
            switch keyCode {
            case kVK_ANSI_K: return "cmd+k"
            case kVK_LeftArrow: return "cmd+left"
            case kVK_RightArrow: return "cmd+right"
            case kVK_Delete: return "cmd+backspace"
            default: return nil
            }
        }

        private static func isPrivateUseFunctionKeyScalar(_ value: UInt32) -> Bool { (0xF700...0xF8FF).contains(value) }
    }
#endif
