import Foundation

public struct StatusCheckDefinition: Codable, Sendable {
    public var name: String?
    public var process: String
    public var command: String
    public var interval: Int
    public var timeout: Int
    public var onExit: StatusCheckOnExit

    public init(name: String? = nil, process: String, command: String, interval: Int, timeout: Int, onExit: StatusCheckOnExit = .none) {
        self.name = name
        self.process = process
        self.command = command
        self.interval = interval
        self.timeout = timeout
        self.onExit = onExit
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case process
        case command
        case interval
        case timeout
        case onExit = "on_exit"
    }
}
