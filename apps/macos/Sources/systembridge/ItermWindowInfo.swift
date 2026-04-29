import Foundation

public struct ItermWindowInfo: Sendable {
    public let id: Int
    public let sessionID: String?
    public let tabIndex: Int?
    public init(id: Int, sessionID: String? = nil, tabIndex: Int? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.tabIndex = tabIndex
    }
}
