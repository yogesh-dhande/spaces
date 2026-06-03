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

    static func rawKeyFallbackSpecifier(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let navigationFlags = flags.subtracting([.numericPad, .function])
        let functionFlags = flags.subtracting(.function)
        switch Int(event.keyCode) {
        case kVK_UpArrow where navigationFlags.isEmpty: return "up"
        case kVK_DownArrow where navigationFlags.isEmpty: return "down"
        case kVK_LeftArrow where navigationFlags.isEmpty: return "left"
        case kVK_RightArrow where navigationFlags.isEmpty: return "right"
        case kVK_LeftArrow where navigationFlags == [.command]: return "cmd+left"
        case kVK_RightArrow where navigationFlags == [.command]: return "cmd+right"
        case kVK_LeftArrow where navigationFlags == [.option]: return "opt+left"
        case kVK_RightArrow where navigationFlags == [.option]: return "opt+right"
        case kVK_Home where navigationFlags.isEmpty: return "home"
        case kVK_End where navigationFlags.isEmpty: return "end"
        case kVK_PageUp where navigationFlags.isEmpty: return "pageup"
        case kVK_PageDown where navigationFlags.isEmpty: return "pagedown"
        case kVK_ForwardDelete where navigationFlags.isEmpty: return "forwarddelete"
        case kVK_Help where navigationFlags.isEmpty: return "insert"
        case kVK_Tab where flags == [.shift]: return "backtab"
        case kVK_F1 where functionFlags.isEmpty: return "f1"
        case kVK_F2 where functionFlags.isEmpty: return "f2"
        case kVK_F3 where functionFlags.isEmpty: return "f3"
        case kVK_F4 where functionFlags.isEmpty: return "f4"
        case kVK_F5 where functionFlags.isEmpty: return "f5"
        case kVK_F6 where functionFlags.isEmpty: return "f6"
        case kVK_F7 where functionFlags.isEmpty: return "f7"
        case kVK_F8 where functionFlags.isEmpty: return "f8"
        case kVK_F9 where functionFlags.isEmpty: return "f9"
        case kVK_F10 where functionFlags.isEmpty: return "f10"
        case kVK_F11 where functionFlags.isEmpty: return "f11"
        case kVK_F12 where functionFlags.isEmpty: return "f12"
        default: return nil
        }
    }

    static func keySpecifier(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let semanticFlags = flags.subtracting([.function, .numericPad])
        if let fallback = rawKeyFallbackSpecifier(for: event) { return fallback }
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "enter"
        case kVK_ANSI_K where semanticFlags == [.command]: return "cmd+k"
        case kVK_Delete where semanticFlags == [.command]: return "cmd+backspace"
        case kVK_Delete where semanticFlags == [.option]: return "opt+backspace"
        case kVK_Delete: return "backspace"
        case kVK_Escape: return "esc"
        case kVK_Tab where flags == [.shift]: return "backtab"
        case kVK_Tab: return "tab"
        default: break
        }
        if flags.contains(.control), let flag = controlKeySpecifier(for: event), !flags.contains(.command), !flags.contains(.option) { return flag }
        return nil
    }

    private static func isPrivateUseFunctionKeyScalar(_ value: UInt32) -> Bool { (0xF700...0xF8FF).contains(value) }

    private static func controlKeySpecifier(for event: NSEvent) -> String? {
        guard let flaglessCharacters = event.charactersIgnoringModifiers, flaglessCharacters.count == 1,
            let scalar = flaglessCharacters.unicodeScalars.first
        else { return nil }
        guard scalar.properties.isAlphabetic else { return nil }
        return "ctrl+\(String(scalar).lowercased())"
    }
}
