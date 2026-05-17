import Foundation

public enum TerminalKeyInput {
    public static func bytes(for spec: String) -> [UInt8]? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed.lowercased() {
        case "enter", "return": return [0x0D]
        case "tab": return [0x09]
        case "backtab": return Array("\u{1B}[Z".utf8)
        case "escape", "esc": return [0x1B]
        case "backspace": return [0x7F]
        case "up": return Array("\u{1B}[A".utf8)
        case "down": return Array("\u{1B}[B".utf8)
        case "right": return Array("\u{1B}[C".utf8)
        case "left": return Array("\u{1B}[D".utf8)
        case "home": return Array("\u{1B}[H".utf8)
        case "end": return Array("\u{1B}[F".utf8)
        case "pageup": return Array("\u{1B}[5~".utf8)
        case "pagedown": return Array("\u{1B}[6~".utf8)
        case "forwarddelete": return Array("\u{1B}[3~".utf8)
        case "insert": return Array("\u{1B}[2~".utf8)
        case "f1": return Array("\u{1B}OP".utf8)
        case "f2": return Array("\u{1B}OQ".utf8)
        case "f3": return Array("\u{1B}OR".utf8)
        case "f4": return Array("\u{1B}OS".utf8)
        case "f5": return Array("\u{1B}[15~".utf8)
        case "f6": return Array("\u{1B}[17~".utf8)
        case "f7": return Array("\u{1B}[18~".utf8)
        case "f8": return Array("\u{1B}[19~".utf8)
        case "f9": return Array("\u{1B}[20~".utf8)
        case "f10": return Array("\u{1B}[21~".utf8)
        case "f11": return Array("\u{1B}[23~".utf8)
        case "f12": return Array("\u{1B}[24~".utf8)
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
