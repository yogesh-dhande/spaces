import Foundation

public enum TerminalTrackingIdentity: Hashable, Sendable {
    case session(String)
    case window(Int)
    case tmux(String)

    public var trackingKey: String {
        switch self {
        case .session(let id): return "terminal:\(id)"
        case .window(let id): return "window:\(id)"
        case .tmux(let id): return "tmux:\(id)"
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

    public var tmuxWindowID: String? {
        if case .tmux(let id) = self { return id }
        return nil
    }
}

public struct TerminalLaunchResult: Sendable {
    /// Stable identity for later focus/reconciliation.
    public let trackingIdentity: TerminalTrackingIdentity?
    /// Shell-emitted hook identity when the launched terminal cannot rediscover its stable native identity itself.
    public let hookSessionID: String?
    public let containerID: String?
    public let fallbackWindowID: Int?
    public let tabIndex: Int?

    public init(
        trackingIdentity: TerminalTrackingIdentity?, hookSessionID: String? = nil, containerID: String?, fallbackWindowID: Int?, tabIndex: Int? = nil
    ) {
        self.trackingIdentity = trackingIdentity
        self.hookSessionID = hookSessionID
        self.containerID = containerID
        self.fallbackWindowID = fallbackWindowID
        self.tabIndex = tabIndex
    }
}

public struct TerminalFocusTarget: Sendable {
    public let trackingIdentity: TerminalTrackingIdentity?
    public let windowID: Int?
    public let tabIndex: Int?

    public init(trackingIdentity: TerminalTrackingIdentity?, windowID: Int?, tabIndex: Int? = nil) {
        self.trackingIdentity = trackingIdentity
        self.windowID = windowID
        self.tabIndex = tabIndex
    }
}

public protocol TerminalAdapter: Sendable {
    var appName: String { get }
    var bundleIdentifier: String { get }

    func isAvailable() -> Bool
    /// Opens a terminal and runs `command` from `cwd`, ensuring `environment` is present in the
    /// launched shell process so later hooks can rely on those values for identity.
    func openWindowAndRun(command: String, cwd: String, environment: [String: String], background: Bool) throws -> TerminalLaunchResult
    func resolveCurrentTrackingIdentity(environment: [String: String], yabaiFocusedWindowID: Int?) throws -> TerminalTrackingIdentity?
    func focusTrackedTerminal(_ target: TerminalFocusTarget) throws -> Bool
    func listLiveTrackingIdentities() throws -> Set<TerminalTrackingIdentity>
}
