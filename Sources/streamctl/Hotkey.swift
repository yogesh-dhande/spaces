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
}

public struct HotkeySpecError: LocalizedError {
    private let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
