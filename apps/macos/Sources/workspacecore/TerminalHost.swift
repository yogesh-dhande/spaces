import Foundation

public enum TerminalHost: String, CaseIterable, Sendable {
    case iterm2 = "iterm2"
    case ghostty = "ghostty"

    public var displayName: String {
        switch self {
        case .iterm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }

    public var appName: String {
        switch self {
        case .iterm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .iterm2: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        }
    }
}
