import Foundation

public struct AgentWindowRecord: Codable, Sendable {
    public let id: String
    public let workspaceID: String
    public let provider: AgentProvider
    public let label: String?
    public let itermSessionID: String?
    public let tmuxWindowID: String?
    public let codexThreadID: String?
    public let windowID: Int?
    /// Yabai window ID of the captured workspace window hosting this agent session.
    public let yabaiWindowID: Int?
    public let status: AgentWindowStatus
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String, workspaceID: String, provider: AgentProvider, label: String?, itermSessionID: String?, tmuxWindowID: String? = nil,
        codexThreadID: String?, windowID: Int?,
        yabaiWindowID: Int? = nil, status: AgentWindowStatus, createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.provider = provider
        self.label = label
        self.itermSessionID = itermSessionID
        self.tmuxWindowID = tmuxWindowID
        self.codexThreadID = codexThreadID
        self.windowID = windowID
        self.yabaiWindowID = yabaiWindowID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
