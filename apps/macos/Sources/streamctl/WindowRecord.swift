import Foundation

public struct WindowRecord: Sendable {
    public let id: String
    public let workspaceID: String
    public let app: String
    public let title: String?
    public let targetURL: String?
    public let windowID: Int?
    public let itermSessionID: String?
    public let itermTabIndex: Int?
    public let role: String
    public let orderIndex: Int
    public let lastSeenAt: String

    public init(
        id: String, workspaceID: String, app: String, title: String?, targetURL: String? = nil, windowID: Int?, itermSessionID: String? = nil,
        itermTabIndex: Int? = nil, role: String, orderIndex: Int, lastSeenAt: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.app = app
        self.title = title
        self.targetURL = targetURL
        self.windowID = windowID
        self.itermSessionID = itermSessionID
        self.itermTabIndex = itermTabIndex
        self.role = role
        self.orderIndex = orderIndex
        self.lastSeenAt = lastSeenAt
    }
}
