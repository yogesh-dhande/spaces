import Foundation

public enum EditorPreference: String, Codable, Sendable, CaseIterable {
    case none = "none"
    case vscode = "vscode"
    case cursor = "cursor"
    case windsurf = "windsurf"
    case vim = "vim"
}
