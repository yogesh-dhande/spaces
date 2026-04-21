import Foundation

@testable import streamctl

extension WindowRecord {
    init(
        id: String, workspaceID: String, app: String, title: String?, targetURL: String? = nil, windowID: Int?, itermSessionID: String? = nil,
        itermTabIndex: Int? = nil, tmuxWindowID: String? = nil, role: String, orderIndex: Int, lastSeenAt: String
    ) {
        self.init(
            id: id, workspaceID: workspaceID, app: app, name: title, detail: nil, targetURL: targetURL, windowID: windowID,
            itermSessionID: itermSessionID, itermTabIndex: itermTabIndex, tmuxWindowID: tmuxWindowID, role: role,
            orderIndex: orderIndex, lastSeenAt: lastSeenAt)
    }

    var title: String? { name }
}
