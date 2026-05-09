import Foundation

public enum TerminalHost: String, CaseIterable, Sendable {
    case spaces = "spaces"
    case iterm2 = "iterm2"
    case ghostty = "ghostty"

    public var displayName: String {
        switch self {
        case .spaces: return "Spaces"
        case .iterm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }

    public var appName: String {
        switch self {
        case .spaces: return "Spaces"
        case .iterm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .spaces: return "com.spaces.app"
        case .iterm2: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        }
    }
}
