import Foundation

public struct StatusCheckDefinition: Codable, Sendable {
    public var name: String?
    public var process: String
    public var command: String
    public var interval: Int
    public var timeout: Int
    public var onFail: OnFailAction

    public init(name: String? = nil, process: String, command: String, interval: Int, timeout: Int, onFail: OnFailAction = .none) {
        self.name = name
        self.process = process
        self.command = command
        self.interval = interval
        self.timeout = timeout
        self.onFail = onFail
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case process
        case command
        case interval
        case timeout
        case onFail = "on_fail"
    }
}
