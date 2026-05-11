import Foundation

public struct WorkspaceTargetGroup: Sendable {
    public let id: String
    public let workspaceID: String
    public let name: String?
    public let orderIndex: Int
    public let createdAt: String
    public let updatedAt: String

    public init(id: String, workspaceID: String, name: String?, orderIndex: Int, createdAt: String, updatedAt: String) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.orderIndex = orderIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
