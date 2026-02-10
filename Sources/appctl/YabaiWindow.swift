import Foundation

public struct YabaiWindow: Decodable, Sendable {
    public let id: Int
    public let pid: Int?
    public let app: String
    public let title: String?
    public let space: Int
    public let display: Int
    public let isSticky: Bool
    public let isHidden: Bool
    public let isVisible: Bool
    public let isNativeFullscreen: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case pid
        case app
        case title
        case space
        case display
        case isSticky = "is-sticky"
        case isHidden = "is-hidden"
        case isVisible = "is-visible"
        case isNativeFullscreen = "is-native-fullscreen"
    }
}
