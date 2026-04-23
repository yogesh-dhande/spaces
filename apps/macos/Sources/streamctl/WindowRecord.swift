import Foundation

public struct WindowRecord: Sendable {
    public let id: String
    public let workspaceID: String
    public let app: String
    public let name: String?
    public let detail: String?
    public let targetURL: String?
    public let windowID: Int?
    public let terminalTrackingID: String?
    public let terminalNativeID: String?
    public let itermTabIndex: Int?
    public let tmuxWindowID: String?
    public let role: String
    public let orderIndex: Int
    public let lastSeenAt: String

    public init(
        id: String, workspaceID: String, app: String, name: String?, detail: String? = nil, targetURL: String? = nil, windowID: Int?,
        terminalTrackingID: String? = nil, terminalNativeID: String? = nil,
        itermTabIndex: Int? = nil, tmuxWindowID: String? = nil, role: String, orderIndex: Int, lastSeenAt: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.app = app
        self.name = name
        self.detail = detail
        self.targetURL = targetURL
        self.windowID = windowID
        self.terminalTrackingID = terminalTrackingID
        self.terminalNativeID = terminalNativeID
        self.itermTabIndex = itermTabIndex
        self.tmuxWindowID = tmuxWindowID
        self.role = role
        self.orderIndex = orderIndex
        self.lastSeenAt = lastSeenAt
    }
}
