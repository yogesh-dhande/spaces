import Foundation

public struct WindowRecord: Sendable {
    public let id: String
    public let workspaceID: String
    public let app: String
    public let name: String?
    public let detail: String?
    public let targetURL: String?
    public let windowID: Int?
    public let itermSessionID: String?
    public let itermTabIndex: Int?
    public let tmuxWindowID: String?
    public let role: String
    public let orderIndex: Int
    public let lastSeenAt: String

    public init(
        id: String, workspaceID: String, app: String, name: String?, detail: String? = nil, targetURL: String? = nil, windowID: Int?,
        itermSessionID: String? = nil,
        itermTabIndex: Int? = nil, tmuxWindowID: String? = nil, role: String, orderIndex: Int, lastSeenAt: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.app = app
        self.name = name
        self.detail = detail
        self.targetURL = targetURL
        self.windowID = windowID
        self.itermSessionID = itermSessionID
        self.itermTabIndex = itermTabIndex
        self.tmuxWindowID = tmuxWindowID
        self.role = role
        self.orderIndex = orderIndex
        self.lastSeenAt = lastSeenAt
    }
}
