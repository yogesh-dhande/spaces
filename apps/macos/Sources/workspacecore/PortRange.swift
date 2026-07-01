import Foundation

public struct PortRange: Codable, Sendable {
    /// Default allocation range used when a daemon has no configured override. The client never
    /// allocates ports itself, so its in-memory `AppConfig` carries this placeholder.
    public static let `default` = PortRange(start: 20000, end: 30000)

    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}
