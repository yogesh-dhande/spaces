import Foundation

public struct BrowserSession: Codable, Sendable {
    public var url: String?
    public var extractedWindow: ExtractedBrowserWindowMapping?

    public init(url: String? = nil, extractedWindow: ExtractedBrowserWindowMapping? = nil) {
        self.url = url
        self.extractedWindow = extractedWindow
    }
}
