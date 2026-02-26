import Foundation

public struct PortDefinition: Codable, Sendable, Equatable {
    public var name: String

    public init(name: String) { self.name = name }
}
