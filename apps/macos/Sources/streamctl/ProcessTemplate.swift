import Foundation

public struct ProcessTemplate: Codable, Sendable {
    public var name: String?
    public var command: String
    public var kind: String?
    public var onExit: ProcessExitAction

    public init(name: String? = nil, command: String, kind: String? = nil, onExit: ProcessExitAction = .none) {
        self.name = name
        self.command = command
        self.kind = kind
        self.onExit = onExit
    }
    private enum CodingKeys: String, CodingKey {
        case name
        case command
        case kind
        case onExit = "on_exit"
    }
}
