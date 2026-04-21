import Foundation

public struct YabaiFrame: Decodable, Sendable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
}

public struct YabaiWindow: Decodable, Sendable {
    public let id: Int
    public let pid: Int?
    public let app: String
    public let title: String?
    public let space: Int
    public let display: Int
    public let isVisible: Bool
    public let frame: YabaiFrame?

    private enum CodingKeys: String, CodingKey {
        case id
        case pid
        case app
        case title
        case space
        case display
        case isVisible = "is-visible"
        case frame
    }
}
