import Foundation

public enum TerminalSessionBackendKind: String, Codable, Sendable, Equatable, CaseIterable {
    case scriptPTY = "script-pty"
    case ghosttyEmbedded = "ghostty-embedded"

    public var displayName: String {
        switch self {
        case .scriptPTY: "script PTY"
        case .ghosttyEmbedded: "libghostty"
        }
    }
}
