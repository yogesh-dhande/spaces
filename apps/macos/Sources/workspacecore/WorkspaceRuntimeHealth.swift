import Foundation

public enum WorkspaceRuntimeHealth: String, Codable, Sendable {
    case healthy
    case partial
    case missing
}
