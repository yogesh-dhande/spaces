import Foundation

@testable import workspacecore

extension WindowRecord {
    init(
        id: String, workspaceID: String, app: String, title: String?, targetURL: String? = nil, windowID: Int?, terminalTrackingID: String? = nil,
        role: String, orderIndex: Int, lastSeenAt: String
    ) {
        self.init(
            id: id, workspaceID: workspaceID, app: app, name: title, detail: nil, targetURL: targetURL, windowID: windowID,
            terminalTrackingID: terminalTrackingID, role: role, orderIndex: orderIndex, lastSeenAt: lastSeenAt)
    }

    var title: String? { name }
}
