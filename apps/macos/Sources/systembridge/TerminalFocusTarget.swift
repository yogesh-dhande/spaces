import Foundation

public enum TerminalTrackingIdentity: Hashable, Sendable {
    case session(String)
    case window(Int)

    public var trackingKey: String {
        switch self {
        case .session(let id): return "terminal:\(id)"
        case .window(let id): return "window:\(id)"
        }
    }

    public var sessionID: String? {
        if case .session(let id) = self { return id }
        return nil
    }

    public var windowID: Int? {
        if case .window(let id) = self { return id }
        return nil
    }
}

public struct TerminalFocusTarget: Sendable {
    /// Stable terminal-provider identity used for direct terminal focus when available.
    public let providerIdentity: TerminalTrackingIdentity?
    public let windowID: Int?

    public init(providerIdentity: TerminalTrackingIdentity?, windowID: Int?) {
        self.providerIdentity = providerIdentity
        self.windowID = windowID
    }
}
