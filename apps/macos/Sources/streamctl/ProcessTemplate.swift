import Foundation

public struct ProcessTemplate: Codable, Sendable {
    public var name: String?
    public var command: String
    public var kind: String?

    public init(name: String? = nil, command: String, kind: String? = nil) {
        self.name = name
        self.command = command
        self.kind = kind
    }
}
