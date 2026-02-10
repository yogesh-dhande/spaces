import Foundation

public struct BrowserSession: Codable, Sendable {
    public var url: String?

    public init(url: String? = nil) {
        self.url = url
    }
}
