import Foundation

public enum TerminalPasteInput {
    public static func wrapped(_ text: String, usesBracketedPasteMode: Bool) -> String {
        guard usesBracketedPasteMode else { return text }
        return "\u{001B}[200~\(text)\u{001B}[201~"
    }
}
