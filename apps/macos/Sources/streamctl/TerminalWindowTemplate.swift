import Foundation

public struct TerminalWindowTemplate: Codable, Sendable, Equatable {
    public var name: String
    public var command: String?

    public init(name: String, command: String? = nil) {
        self.name = name
        self.command = command
    }
}
