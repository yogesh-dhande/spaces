import Foundation

/// A key press named by a client: which key, with which modifiers held.
///
/// This is the whole of what a client knows. Turning it into bytes is the session host's job,
/// because only the host holds the terminal state the encoding depends on.
public struct TerminalKeySpec: Equatable, Sendable {
    public let key: TerminalKey
    public let modifiers: TerminalKeyModifiers

    public init(key: TerminalKey, modifiers: TerminalKeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}
