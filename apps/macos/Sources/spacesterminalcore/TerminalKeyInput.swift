import Foundation

public enum TerminalKeyInput {
    public static func bytes(for spec: String) -> [UInt8]? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed.lowercased() {
        case "enter", "return": return [0x0D]
        case "tab": return [0x09]
        case "escape", "esc": return [0x1B]
        case "backspace": return [0x7F]
        case "up": return Array("\u{1B}[A".utf8)
        case "down": return Array("\u{1B}[B".utf8)
        case "right": return Array("\u{1B}[C".utf8)
        case "left": return Array("\u{1B}[D".utf8)
        default: break
        }

        let normalized = trimmed.replacingOccurrences(of: "-", with: "+")
        let parts = normalized.split(separator: "+").map { $0.lowercased() }
        guard parts.count == 2, parts[0] == "ctrl", let scalar = parts[1].unicodeScalars.only else { return nil }
        guard scalar.properties.isAlphabetic else { return nil }
        let uppercase = String(parts[1]).uppercased().unicodeScalars.first?.value ?? scalar.value
        let controlValue = uppercase & 0x1F
        return [UInt8(controlValue)]
    }
}

extension Collection { fileprivate var only: Element? { count == 1 ? first : nil } }
