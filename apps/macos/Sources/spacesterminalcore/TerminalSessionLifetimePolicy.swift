import Foundation

public enum TerminalSessionLifetimePolicy: String, Codable, Sendable, Equatable, CaseIterable {
    case persistent = "persistent"
    case whileAttached = "while_attached"
}
