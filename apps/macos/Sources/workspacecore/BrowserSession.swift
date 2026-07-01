import Foundation

public struct BrowserSession: Codable, Sendable {
    public var name: String?
    public var url: String?

    public init(name: String? = nil, url: String? = nil) {
        self.name = name
        self.url = url
    }
}
