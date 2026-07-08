import Foundation

public struct AgentWindowRecord: Codable, Sendable {
    public let id: String
    public let workspaceID: String
    public let provider: AgentProvider
    public let label: String?
    public let runtimeTargetID: String?
    public let terminalTarget: TerminalTargetRecord?
    public let sessionKey: String?
    public let claimedLauncherID: String?
    public let claimedLauncherName: String?
    public let status: AgentWindowStatus
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String, workspaceID: String, provider: AgentProvider, label: String?, runtimeTargetID: String? = nil,
        terminalTarget: TerminalTargetRecord? = nil, sessionKey: String? = nil, claimedLauncherID: String? = nil, claimedLauncherName: String? = nil,
        status: AgentWindowStatus, createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.provider = provider
        self.label = label
        self.runtimeTargetID = runtimeTargetID
        self.terminalTarget = terminalTarget
        self.sessionKey = sessionKey
        self.claimedLauncherID = claimedLauncherID
        self.claimedLauncherName = claimedLauncherName
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(
        id: String, workspaceID: String, provider: AgentProvider, label: String?, runtimeTargetID: String? = nil, terminalTrackingID: String?,
        sessionKey: String?, status: AgentWindowStatus, createdAt: String, updatedAt: String
    ) {
        let terminalTarget: TerminalTargetRecord? =
            if terminalTrackingID != nil { TerminalTargetRecord(runtimeTargetID: runtimeTargetID, trackingID: terminalTrackingID) } else { nil }
        self.init(
            id: id, workspaceID: workspaceID, provider: provider, label: label, runtimeTargetID: runtimeTargetID, terminalTarget: terminalTarget,
            sessionKey: sessionKey, status: status, createdAt: createdAt, updatedAt: updatedAt)
    }

    public init(
        id: String, workspaceID: String, provider: AgentProvider, label: String?, terminalTrackingID: String?,
        sessionKey: String?, status: AgentWindowStatus, createdAt: String, updatedAt: String
    ) {
        self.init(
            id: id, workspaceID: workspaceID, provider: provider, label: label, runtimeTargetID: nil, terminalTrackingID: terminalTrackingID,
            sessionKey: sessionKey, status: status, createdAt: createdAt, updatedAt: updatedAt)
    }

    public var terminalTrackingID: String? { terminalTarget?.trackingID }
}
