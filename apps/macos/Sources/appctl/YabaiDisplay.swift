import Foundation

public struct YabaiDisplay: Decodable, Sendable {
    public let id: Int?
    public let index: Int
    public let frame: YabaiFrame?
}
