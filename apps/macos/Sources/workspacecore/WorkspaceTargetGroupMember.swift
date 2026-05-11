import Foundation

public struct WorkspaceTargetGroupMember: Sendable {
    public enum Kind: String, Sendable {
        case browserSession = "browser_session"
        case process
        case agentWindow = "agent_window"
        case window
    }

    public let groupID: String
    public let orderIndex: Int
    public let kind: Kind
    public let referenceID: String

    public init(groupID: String, orderIndex: Int, kind: Kind, referenceID: String) {
        self.groupID = groupID
        self.orderIndex = orderIndex
        self.kind = kind
        self.referenceID = referenceID
    }
}
