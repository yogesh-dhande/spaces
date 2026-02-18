import Foundation

public struct BrowserSession: Codable, Sendable {
    public var name: String?
    public var url: String?
    public var extractedWindow: ExtractedBrowserWindowMapping?

    public init(name: String? = nil, url: String? = nil, extractedWindow: ExtractedBrowserWindowMapping? = nil) {
        self.name = name
        self.url = url
        self.extractedWindow = extractedWindow
    }
}
