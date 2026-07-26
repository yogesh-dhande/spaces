/// UserDefaults key backing the `@AppStorage`-bound terminal font size selection. Distinct from
/// the connection settings blob so switching devices or clearing pairing never resets it.
enum TerminalFontSizeStorage {
    static let key = "spaces.mobile.terminal-font-size"
}
