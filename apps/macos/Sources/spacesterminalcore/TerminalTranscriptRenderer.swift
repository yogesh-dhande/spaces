import Foundation

enum TerminalTranscriptRenderer {
    static func render(_ text: String) -> String {
        let hasEscapeSequences = text.unicodeScalars.contains("\u{001B}")
        let hasControlCharacters = text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x08, 0x0D: return true
            default: return false
            }
        }
        guard hasEscapeSequences || hasControlCharacters else { return text }

        var buffer = TerminalScreenBuffer()
        buffer.ingest(text)
        return buffer.renderedText()
    }
}
