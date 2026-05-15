import Foundation

public enum TerminalSessionBackendKind: String, Codable, Sendable, Equatable, CaseIterable {
    case ghosttyEmbedded = "ghostty-embedded"

    public var displayName: String {
        switch self {
        case .ghosttyEmbedded: "libghostty"
        }
    }
}
