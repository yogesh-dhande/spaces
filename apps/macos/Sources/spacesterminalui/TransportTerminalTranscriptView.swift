import AppKit
import Carbon

@MainActor enum TransportTerminalTranscriptInput: Equatable {
    case text(String)
    case key(String)
}

@MainActor final class TransportTerminalTranscriptView: NSTextView {
    var terminalInputHandler: ((TransportTerminalTranscriptInput) -> Bool)?
    var terminalPasteHandler: (() -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard handleTerminalEvent(event) else {
            super.keyDown(with: event)
            return
        }
    }

    override func paste(_ sender: Any?) {
        guard terminalPasteHandler?() != true else { return }
        super.paste(sender)
    }

    @discardableResult func handleTerminalEvent(_ event: NSEvent) -> Bool {
        guard let input = terminalInput(for: event) else { return false }
        return terminalInputHandler?(input) ?? false
    }

    private func terminalInput(for event: NSEvent) -> TransportTerminalTranscriptInput? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return nil }

        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return .key("enter")
        case kVK_Tab: return .key(flags.contains(.shift) ? "backtab" : "tab")
        case kVK_Delete: return .key("backspace")
        case kVK_ForwardDelete: return .key("forwarddelete")
        case kVK_Escape: return .key("esc")
        case kVK_UpArrow: return .key("up")
        case kVK_DownArrow: return .key("down")
        case kVK_LeftArrow: return .key("left")
        case kVK_RightArrow: return .key("right")
        case kVK_Home: return .key("home")
        case kVK_End: return .key("end")
        case kVK_PageUp: return .key("pageup")
        case kVK_PageDown: return .key("pagedown")
        case kVK_F1: return .key("f1")
        case kVK_F2: return .key("f2")
        case kVK_F3: return .key("f3")
        case kVK_F4: return .key("f4")
        case kVK_F5: return .key("f5")
        case kVK_F6: return .key("f6")
        case kVK_F7: return .key("f7")
        case kVK_F8: return .key("f8")
        case kVK_F9: return .key("f9")
        case kVK_F10: return .key("f10")
        case kVK_F11: return .key("f11")
        case kVK_F12: return .key("f12")
        default: break
        }

        if flags.contains(.control), let scalar = event.charactersIgnoringModifiers?.unicodeScalars.only, scalar.properties.isAlphabetic {
            return .key("ctrl+\(String(scalar).lowercased())")
        }

        guard !flags.contains(.control) else { return nil }
        guard let text = event.characters, !text.isEmpty else { return nil }
        guard text.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return .text(text)
    }
}

extension Collection { fileprivate var only: Element? { count == 1 ? first : nil } }
