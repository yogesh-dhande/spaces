import Foundation

public enum TerminalKeyInput {
    public static func bytes(for spec: String) -> [UInt8]? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.lowercased().replacingOccurrences(of: "-", with: "+")
        if let modified = bytesForModifiedKey(spec: normalized) { return modified }

        switch normalized {
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
        case "f13": return Array("\u{1B}[25~".utf8)
        case "f14": return Array("\u{1B}[26~".utf8)
        case "f15": return Array("\u{1B}[28~".utf8)
        case "f16": return Array("\u{1B}[29~".utf8)
        case "f17": return Array("\u{1B}[31~".utf8)
        case "f18": return Array("\u{1B}[32~".utf8)
        case "f19": return Array("\u{1B}[33~".utf8)
        case "f20": return Array("\u{1B}[34~".utf8)
        case "kpenter": return [0x0D]
        case "kpclear": return Array("\u{1B}[E".utf8)
        default: break
        }

        let parts = normalized.split(separator: "+").map { $0.lowercased() }
        guard parts.count == 2, parts[0] == "ctrl", let scalar = parts[1].unicodeScalars.only else { return nil }
        guard scalar.properties.isAlphabetic else { return nil }
        let uppercase = String(parts[1]).uppercased().unicodeScalars.first?.value ?? scalar.value
        let controlValue = uppercase & 0x1F
        return [UInt8(controlValue)]
    }

    private static func bytesForModifiedKey(spec: String) -> [UInt8]? {
        let parts = spec.split(separator: "+").map(String.init)
        guard parts.count >= 2 else { return nil }
        let key = parts.last ?? ""
        let modifiers = Set(parts.dropLast())
        guard modifiers.allSatisfy({ ["shift", "alt", "option", "meta", "ctrl", "control"].contains($0) }) else { return nil }
        guard !modifiers.isEmpty else { return nil }

        let normalizedModifiers = NormalizedModifiers(
            shift: modifiers.contains("shift"), alt: modifiers.contains("alt") || modifiers.contains("option") || modifiers.contains("meta"),
            control: modifiers.contains("ctrl") || modifiers.contains("control"))
        guard let parameter = normalizedModifiers.xtermParameter else { return nil }

        if let cursorFinal = modifiedCursorFinal(for: key) { return Array("\u{1B}[1;\(parameter)\(cursorFinal)".utf8) }
        if let tildeCode = modifiedTildeCode(for: key) { return Array("\u{1B}[\(tildeCode);\(parameter)~".utf8) }
        if let functionFinal = modifiedFunctionFinal(for: key) { return Array("\u{1B}[1;\(parameter)\(functionFinal)".utf8) }
        return nil
    }

    private static func modifiedCursorFinal(for key: String) -> String? {
        switch key {
        case "up": return "A"
        case "down": return "B"
        case "right": return "C"
        case "left": return "D"
        case "home": return "H"
        case "end": return "F"
        default: return nil
        }
    }

    private static func modifiedTildeCode(for key: String) -> String? {
        switch key {
        case "insert": return "2"
        case "forwarddelete": return "3"
        case "pageup": return "5"
        case "pagedown": return "6"
        case "f5": return "15"
        case "f6": return "17"
        case "f7": return "18"
        case "f8": return "19"
        case "f9": return "20"
        case "f10": return "21"
        case "f11": return "23"
        case "f12": return "24"
        case "f13": return "25"
        case "f14": return "26"
        case "f15": return "28"
        case "f16": return "29"
        case "f17": return "31"
        case "f18": return "32"
        case "f19": return "33"
        case "f20": return "34"
        default: return nil
        }
    }

    private static func modifiedFunctionFinal(for key: String) -> String? {
        switch key {
        case "f1": return "P"
        case "f2": return "Q"
        case "f3": return "R"
        case "f4": return "S"
        default: return nil
        }
    }
}

private struct NormalizedModifiers {
    let shift: Bool
    let alt: Bool
    let control: Bool

    var xtermParameter: Int? {
        switch (shift, alt, control) {
        case (false, false, false): return nil
        case (true, false, false): return 2
        case (false, true, false): return 3
        case (true, true, false): return 4
        case (false, false, true): return 5
        case (true, false, true): return 6
        case (false, true, true): return 7
        case (true, true, true): return 8
        }
    }
}

extension Collection { fileprivate var only: Element? { count == 1 ? first : nil } }
