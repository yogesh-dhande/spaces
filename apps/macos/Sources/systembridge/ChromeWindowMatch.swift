import Foundation

public struct ChromeWindowMatch: Sendable {
    public let windowID: Int
    public let tabIndex: Int
    public let title: String
    public let url: String

    public init(windowID: Int, tabIndex: Int, title: String, url: String) {
        self.windowID = windowID
        self.tabIndex = tabIndex
        self.title = title
        self.url = url
    }
}
