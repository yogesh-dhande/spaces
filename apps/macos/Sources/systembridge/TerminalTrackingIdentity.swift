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
