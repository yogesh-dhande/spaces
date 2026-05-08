import Foundation

public struct AgentWindowRecord: Codable, Sendable {
    public let id: String
    public let workspaceID: String
    public let provider: AgentProvider
    public let label: String?
    public let runtimeTargetID: String?
    public let terminalTarget: TerminalTargetRecord?
    public let sessionKey: String?
    public let claimedLauncherName: String?
    public let status: AgentWindowStatus
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String, workspaceID: String, provider: AgentProvider, label: String?, runtimeTargetID: String? = nil,
        terminalTarget: TerminalTargetRecord? = nil, sessionKey: String? = nil, claimedLauncherName: String? = nil, status: AgentWindowStatus,
        createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.provider = provider
        self.label = label
        self.runtimeTargetID = runtimeTargetID
        self.terminalTarget = terminalTarget
        self.sessionKey = sessionKey
        self.claimedLauncherName = claimedLauncherName
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(
        id: String, workspaceID: String, provider: AgentProvider, label: String?, runtimeTargetID: String? = nil, terminalTrackingID: String?,
        terminalNativeID: String? = nil, tmuxWindowID: String? = nil, codexThreadID: String?, windowID: Int?, yabaiWindowID: Int? = nil,
        status: AgentWindowStatus, createdAt: String, updatedAt: String
    ) {
        let resolvedWindowID = yabaiWindowID ?? windowID
        let terminalTarget: TerminalTargetRecord? =
            if terminalTrackingID != nil || terminalNativeID != nil || tmuxWindowID != nil || resolvedWindowID != nil {
                TerminalTargetRecord(
                    app: TerminalHost(rawValue: provider.rawValue)?.appName ?? TerminalHost.iterm2.appName, windowID: resolvedWindowID,
                    provider: provider.rawValue, trackingID: terminalTrackingID, nativeID: terminalNativeID, tmuxWindowID: tmuxWindowID)
            } else { nil }
        self.init(
            id: id, workspaceID: workspaceID, provider: provider, label: label, runtimeTargetID: runtimeTargetID, terminalTarget: terminalTarget,
            sessionKey: codexThreadID, status: status, createdAt: createdAt, updatedAt: updatedAt)
    }

    public init(
        id: String, workspaceID: String, provider: AgentProvider, label: String?, terminalTrackingID: String?, terminalNativeID: String? = nil,
        tmuxWindowID: String? = nil, codexThreadID: String?, windowID: Int?, yabaiWindowID: Int? = nil, status: AgentWindowStatus, createdAt: String,
        updatedAt: String
    ) {
        self.init(
            id: id, workspaceID: workspaceID, provider: provider, label: label, runtimeTargetID: nil, terminalTrackingID: terminalTrackingID,
            terminalNativeID: terminalNativeID, tmuxWindowID: tmuxWindowID, codexThreadID: codexThreadID, windowID: windowID,
            yabaiWindowID: yabaiWindowID, status: status, createdAt: createdAt, updatedAt: updatedAt)
    }

    public var terminalTrackingID: String? { terminalTarget?.trackingID }
    public var terminalNativeID: String? { terminalTarget?.nativeID }
    public var tmuxWindowID: String? { terminalTarget?.tmuxWindowID }
    public var codexThreadID: String? { sessionKey }
    public var windowID: Int? { terminalTarget?.windowID }
    /// Yabai window ID of the captured workspace window hosting this agent session.
    public var yabaiWindowID: Int? { terminalTarget?.windowID }
}
