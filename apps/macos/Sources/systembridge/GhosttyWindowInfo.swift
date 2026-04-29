import Foundation

public struct GhosttyWindowInfo: Sendable {
    public let windowID: String
    public let tabID: String
    public let terminalID: String

    public init(windowID: String, tabID: String, terminalID: String) {
        self.windowID = windowID
        self.tabID = tabID
        self.terminalID = terminalID
    }
}
