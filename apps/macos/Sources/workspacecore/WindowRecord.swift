import Foundation

public enum WindowRole: Sendable, Hashable, Codable {
    case browser
    case terminal
    case editor
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "browser": self = .browser
        case "terminal": self = .terminal
        case "editor": self = .editor
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .browser: "browser"
        case .terminal: "terminal"
        case .editor: "editor"
        case .unknown(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
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
