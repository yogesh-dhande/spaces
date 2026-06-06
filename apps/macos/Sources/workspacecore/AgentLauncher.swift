import Foundation

public struct AgentLauncher: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var command: String

    public init(id: String = UUID().uuidString, name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }
}
