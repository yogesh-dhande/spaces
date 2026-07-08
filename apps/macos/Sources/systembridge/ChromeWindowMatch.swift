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

public struct ChromeTabSnapshot: Sendable {
    public let tabs: [ChromeWindowMatch]
    public let frontmostActiveTabURL: String?

    public init(tabs: [ChromeWindowMatch], frontmostActiveTabURL: String?) {
        self.tabs = tabs
        self.frontmostActiveTabURL = frontmostActiveTabURL
    }
}
