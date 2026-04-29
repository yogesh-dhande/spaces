import Foundation

public struct AgentLauncher: Codable, Sendable, Equatable {
    public var name: String
    public var command: String

    public init(name: String, command: String) {
        self.name = name
        self.command = command
    }
}
