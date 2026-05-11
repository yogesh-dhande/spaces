import Foundation

public enum AgentProvider: String, Codable, Sendable {
    case iterm2 = "iterm2"
    case ghostty = "ghostty"
    case spaces = "spaces"
}
