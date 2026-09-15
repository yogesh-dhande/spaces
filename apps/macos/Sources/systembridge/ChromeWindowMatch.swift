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
    /// The id of Chrome's front window. Window cycling needs it because two workspaces can configure
    /// the same target URL, and then the frontmost tab's URL alone cannot say which of them the user
    /// is standing in; the window id can, because each workspace's browser windows are tracked.
    public let frontmostWindowID: Int?

    public init(tabs: [ChromeWindowMatch], frontmostActiveTabURL: String?, frontmostWindowID: Int?) {
        self.tabs = tabs
        self.frontmostActiveTabURL = frontmostActiveTabURL
        self.frontmostWindowID = frontmostWindowID
    }
}
