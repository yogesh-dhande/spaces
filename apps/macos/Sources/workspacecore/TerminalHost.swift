import Foundation

public enum TerminalHost: String, Sendable {
    case spaces = "spaces"

    public var displayName: String { "Spaces" }

    public var appName: String { "Spaces" }

    public var bundleIdentifier: String { "com.spaces.app" }
}
