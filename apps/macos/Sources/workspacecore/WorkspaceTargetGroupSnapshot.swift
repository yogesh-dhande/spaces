import Foundation

public struct WorkspaceTargetGroupSnapshot: Sendable {
    public let group: WorkspaceTargetGroup
    public let members: [WorkspaceTargetGroupMember]

    public init(group: WorkspaceTargetGroup, members: [WorkspaceTargetGroupMember]) {
        self.group = group
        self.members = members
    }
}
