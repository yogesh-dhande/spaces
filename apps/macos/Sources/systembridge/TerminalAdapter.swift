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
    /// Stable terminal-provider identity for later focus/reconciliation.
    public let providerIdentity: TerminalTrackingIdentity?
    /// Shell-emitted identity used to attribute later hook events to this launched terminal.
    public let hookAttributionID: String?
    public let containerIdentity: String?
    public let fallbackWindowID: Int?

    public init(providerIdentity: TerminalTrackingIdentity?, hookAttributionID: String? = nil, containerIdentity: String?, fallbackWindowID: Int?) {
        self.providerIdentity = providerIdentity
        self.hookAttributionID = hookAttributionID
        self.containerIdentity = containerIdentity
        self.fallbackWindowID = fallbackWindowID
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

public protocol TerminalAdapter: Sendable {
    var appName: String { get }
    var bundleIdentifier: String { get }

    func isAvailable() -> Bool
    /// Opens a terminal and runs `command` from `cwd`, ensuring `environment` is present in the
    /// launched shell process so later hooks can rely on those values for identity.
    func openWindowAndRun(command: String, cwd: String, environment: [String: String], background: Bool) throws -> TerminalLaunchResult
    /// Resolves the identity emitted by the current shell/hook process for event attribution.
    func resolveCurrentAttributionIdentity(environment: [String: String], yabaiFocusedWindowID: Int?) throws -> TerminalTrackingIdentity?
    func focusTrackedTerminal(_ target: TerminalFocusTarget) throws -> Bool
    /// Lists currently live terminal-provider identities for reconciliation and liveness checks.
    func listLiveProviderIdentities() throws -> Set<TerminalTrackingIdentity>
}
