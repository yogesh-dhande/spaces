import Foundation

public enum TerminalTrackingIdentity: Hashable, Sendable {
    case session(String)

    public var trackingKey: String {
        switch self {
        case .session(let id): return "terminal:\(id)"
        }
    }

    public var sessionID: String? {
        if case .session(let id) = self { return id }
        return nil
    }
}
