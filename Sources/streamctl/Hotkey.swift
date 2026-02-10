import Carbon
import Foundation

public enum HotkeyModifier: String, CaseIterable, Sendable {
    case cmd
    case shift
    case alt
    case ctrl
}

public struct HotkeySpec: Sendable, Equatable {
    public let key: String
    public let modifiers: Set<HotkeyModifier>

    public init(key: String, modifiers: Set<HotkeyModifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    public var normalized: String {
        let order: [HotkeyModifier] = [.cmd, .shift, .alt, .ctrl]
        let parts = order.filter { modifiers.contains($0) }.map { $0.rawValue }
        if parts.isEmpty { return key }
        return (parts + [key]).joined(separator: "+")
    }

    public var keyCode: UInt32 {
        if let code = HotkeySpec.keyCodeMap[key] {
            return code
        }
        return UInt32(kVK_ANSI_A)
    }

    public var modifiersCarbon: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.cmd) { result |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.alt) { result |= UInt32(optionKey) }
        if modifiers.contains(.ctrl) { result |= UInt32(controlKey) }
        return result
    }

    public static func parse(_ raw: String) throws -> HotkeySpec {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HotkeySpecError("Hotkey cannot be empty")
        }

        let normalizedRaw = trimmed
            .lowercased()
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let tokens = normalizedRaw.split { $0 == " " || $0 == "\t" }
        guard !tokens.isEmpty else {
            throw HotkeySpecError("Hotkey cannot be empty")
        }

        var modifiers = Set<HotkeyModifier>()
        var keyToken: String?

        for tokenSub in tokens {
            let token = String(tokenSub)
            if let modifier = parseModifier(token) {
                modifiers.insert(modifier)
                continue
            }
            if keyToken != nil {
                throw HotkeySpecError("Hotkey has multiple keys: \(keyToken ?? "") and \(token)")
            }
            if let canonicalKey = canonicalKeyName(token) {
                keyToken = canonicalKey
            } else {
                throw HotkeySpecError("Unsupported key: \(token)")
            }
        }

        guard let key = keyToken else {
            throw HotkeySpecError("Hotkey is missing a key")
        }

        return HotkeySpec(key: key, modifiers: modifiers)
    }

    private static func parseModifier(_ token: String) -> HotkeyModifier? {
        switch token {
        case "cmd", "command":
            return .cmd
        case "shift":
            return .shift
        case "alt", "option", "opt":
            return .alt
        case "ctrl", "control":
            return .ctrl
        default:
            return nil
        }
    }

    private static func canonicalKeyName(_ token: String) -> String? {
        if token.count == 1, let char = token.unicodeScalars.first {
            if CharacterSet.letters.contains(char) {
                return token
            }
            if CharacterSet.decimalDigits.contains(char) {
                return token
            }
            let allowedPunctuation: Set<String> = ["[", "]", ";", "'", ",", ".", "/", "\\", "=", "`"]
            if allowedPunctuation.contains(token) {
                return token
            }
        }

        switch token {
        case "minus", "dash":
            return "minus"
        case "equals", "equal":
            return "="
        case "backslash":
            return "\\"
        case "slash":
            return "/"
        case "comma":
            return ","
        case "period", "dot":
            return "."
        case "quote", "apostrophe":
            return "'"
        case "semicolon":
            return ";"
        case "leftbracket", "lbracket":
            return "["
        case "rightbracket", "rbracket":
            return "]"
        case "grave", "backtick":
            return "`"
        case "space", "spacebar":
            return "space"
        case "tab":
            return "tab"
        case "return":
            return "return"
        case "enter":
            return "enter"
        case "esc", "escape":
            return "escape"
        case "delete", "del":
            return "delete"
        case "backspace":
            return "backspace"
        case "forwarddelete", "forward-delete":
            return "forwarddelete"
        case "left", "right", "up", "down":
            return token
        default:
            break
        }

        if token.hasPrefix("f"), token.count >= 2 {
            let suffix = token.dropFirst()
            if let value = Int(suffix), value >= 1, value <= 20 {
                return "f\(value)"
            }
        }

        return nil
    }

    private static let keyCodeMap: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A),
        "b": UInt32(kVK_ANSI_B),
        "c": UInt32(kVK_ANSI_C),
        "d": UInt32(kVK_ANSI_D),
        "e": UInt32(kVK_ANSI_E),
        "f": UInt32(kVK_ANSI_F),
        "g": UInt32(kVK_ANSI_G),
        "h": UInt32(kVK_ANSI_H),
        "i": UInt32(kVK_ANSI_I),
        "j": UInt32(kVK_ANSI_J),
        "k": UInt32(kVK_ANSI_K),
        "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M),
        "n": UInt32(kVK_ANSI_N),
        "o": UInt32(kVK_ANSI_O),
        "p": UInt32(kVK_ANSI_P),
        "q": UInt32(kVK_ANSI_Q),
        "r": UInt32(kVK_ANSI_R),
        "s": UInt32(kVK_ANSI_S),
        "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U),
        "v": UInt32(kVK_ANSI_V),
        "w": UInt32(kVK_ANSI_W),
        "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y),
        "z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0),
        "1": UInt32(kVK_ANSI_1),
        "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4),
        "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6),
        "7": UInt32(kVK_ANSI_7),
        "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9),
        "=": UInt32(kVK_ANSI_Equal),
        "minus": UInt32(kVK_ANSI_Minus),
        "[": UInt32(kVK_ANSI_LeftBracket),
        "]": UInt32(kVK_ANSI_RightBracket),
        ";": UInt32(kVK_ANSI_Semicolon),
        "'": UInt32(kVK_ANSI_Quote),
        ",": UInt32(kVK_ANSI_Comma),
        ".": UInt32(kVK_ANSI_Period),
        "/": UInt32(kVK_ANSI_Slash),
        "\\": UInt32(kVK_ANSI_Backslash),
        "`": UInt32(kVK_ANSI_Grave),
        "space": UInt32(kVK_Space),
        "tab": UInt32(kVK_Tab),
        "return": UInt32(kVK_Return),
        "enter": UInt32(kVK_Return),
        "escape": UInt32(kVK_Escape),
        "delete": UInt32(kVK_Delete),
        "backspace": UInt32(kVK_Delete),
        "forwarddelete": UInt32(kVK_ForwardDelete),
        "left": UInt32(kVK_LeftArrow),
        "right": UInt32(kVK_RightArrow),
        "up": UInt32(kVK_UpArrow),
        "down": UInt32(kVK_DownArrow)
    ]
}

public struct HotkeySpecError: LocalizedError {
    private let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
