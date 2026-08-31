import Foundation
import workspacecore

extension WindowRecord {
    public init(
        id: String, workspaceID: String, app: String, title: String?, targetURL: String? = nil, terminalTrackingID: String? = nil, role: String,
        orderIndex: Int, lastSeenAt: String
    ) {
        self.init(
            id: id, workspaceID: workspaceID, app: app, name: title, detail: nil, targetURL: targetURL, terminalTrackingID: terminalTrackingID,
            role: role, orderIndex: orderIndex, lastSeenAt: lastSeenAt)
    }

    public var title: String? { name }
}
