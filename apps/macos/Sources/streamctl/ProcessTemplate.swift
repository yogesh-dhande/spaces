import Foundation

public struct ProcessTemplate: Codable, Sendable {
    public var id: String
    public var name: String?
    public var command: String
    public var kind: String?
    public var onExit: ProcessExitAction

    public init(id: String = UUID().uuidString, name: String? = nil, command: String, kind: String? = nil, onExit: ProcessExitAction = .none) {
        self.id = id
        self.name = name
        self.command = command
        self.kind = kind
        self.onExit = onExit
    }
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case kind
        case onExit = "on_exit"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        onExit = try container.decodeIfPresent(ProcessExitAction.self, forKey: .onExit) ?? .none
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encode(onExit, forKey: .onExit)
    }
}
