import Foundation

/// Typed view over a `runtime_targets.type` string. Persistence tracks exactly two focusable runtime
/// roles today (browser and every other runtime item, which is a terminal), so any non-`browser` value
/// reads back as `.terminal` — mirroring the store's own browser-vs-terminal collapse. Add a case here
/// only alongside the persistence and orchestration that give it real behavior.
public enum WindowRole: Sendable, Hashable {
    case browser
    case terminal

    public init(rawValue: String) { self = rawValue == "browser" ? .browser : .terminal }

    public var rawValue: String {
        switch self {
        case .browser: "browser"
        case .terminal: "terminal"
        }
    }
}

public struct WindowRecord: Sendable {
    public let id: String
    public let workspaceID: String
    public let app: String
    public let name: String?
    public let detail: String?
    public let targetURL: String?
    public let terminalTrackingID: String?
    public let terminalNativeID: String?
    public let role: String
    public let orderIndex: Int
    public let lastSeenAt: String

    public init(
        id: String, workspaceID: String, app: String, name: String?, detail: String? = nil, targetURL: String? = nil,
        terminalTrackingID: String? = nil, terminalNativeID: String? = nil, role: String, orderIndex: Int, lastSeenAt: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.app = app
        self.name = name
        self.detail = detail
        self.targetURL = targetURL
        self.terminalTrackingID = terminalTrackingID
        self.terminalNativeID = terminalNativeID
        self.role = role
        self.orderIndex = orderIndex
        self.lastSeenAt = lastSeenAt
    }

    public init(
        id: String, workspaceID: String, app: String, name: String?, detail: String? = nil, targetURL: String? = nil,
        terminalTrackingID: String? = nil, terminalNativeID: String? = nil, role: WindowRole, orderIndex: Int, lastSeenAt: String
    ) {
        self.init(
            id: id, workspaceID: workspaceID, app: app, name: name, detail: detail, targetURL: targetURL, terminalTrackingID: terminalTrackingID,
            terminalNativeID: terminalNativeID, role: role.rawValue, orderIndex: orderIndex, lastSeenAt: lastSeenAt)
    }

    public var roleValue: WindowRole { WindowRole(rawValue: role) }
}
