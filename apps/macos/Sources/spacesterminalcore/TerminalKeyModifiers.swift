import Foundation

/// The modifiers a terminal key spec can carry.
public struct TerminalKeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = TerminalKeyModifiers(rawValue: 1 << 0)
    public static let control = TerminalKeyModifiers(rawValue: 1 << 1)
    public static let option = TerminalKeyModifiers(rawValue: 1 << 2)
    public static let command = TerminalKeyModifiers(rawValue: 1 << 3)

    /// Parses a single lowercased modifier token. Returns nil for anything else, which is how an
    /// unknown token makes the whole spec unresolvable rather than silently dropping a modifier.
    init?(token: String) {
        switch token {
        case "shift": self = .shift
        case "ctrl", "control": self = .control
        case "opt", "option", "alt", "meta": self = .option
        case "cmd", "command": self = .command
        default: return nil
        }
    }
}
