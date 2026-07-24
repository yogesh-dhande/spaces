import Foundation

/// A key a client can name in a terminal key spec.
///
/// Clients name the key they pressed rather than the bytes it should produce: the same key press
/// encodes differently depending on what the running application asked for (the Kitty keyboard
/// protocol, DECCKM cursor-key application mode, `modifyOtherKeys`), and only the session host
/// holds that terminal state. See `TerminalKeyInput` for the resolution rules.
public enum TerminalKey: Equatable, Sendable {
    case enter
    case tab
    case backspace
    case escape
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case forwardDelete
    case insert
    /// `f1` through `f12`.
    case function(Int)
    /// A printable key named by its unshifted character, such as the `c` in `ctrl+c`.
    case character(Character)

    /// The function-key numbers the vocabulary carries. Ghostty encodes higher function keys, but
    /// no Spaces client can produce them, so naming them would be vocabulary no caller can reach.
    static let functionKeyNumbers = 1...12

    /// Parses a single lowercased key name. Returns nil for anything the vocabulary does not name.
    init?(name: String) {
        switch name {
        case "enter", "return": self = .enter
        case "tab": self = .tab
        case "backspace", "delete": self = .backspace
        case "escape", "esc": self = .escape
        case "up": self = .up
        case "down": self = .down
        case "left": self = .left
        case "right": self = .right
        case "home": self = .home
        case "end": self = .end
        case "pageup": self = .pageUp
        case "pagedown": self = .pageDown
        case "forwarddelete": self = .forwardDelete
        case "insert": self = .insert
        default:
            if name.first == "f", let number = Int(name.dropFirst()), Self.functionKeyNumbers.contains(number) {
                self = .function(number)
                return
            }
            guard name.count == 1, let character = name.first, !character.isWhitespace else { return nil }
            self = .character(character)
        }
    }
}
