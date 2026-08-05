import Foundation

public struct AgentWindowRecord: Codable, Sendable {
    public let id: String
    public let workspaceID: String
    public let provider: AgentProvider
    public let label: String?
    /// The name the user typed for this agent's row, or nil when it was never renamed. Kept apart from
    /// `label`, which the hook and foreground-detection writers rewrite from what the agent reports, so a
    /// rename survives every later signal. Only the rename path writes it (see
    /// `SQLiteStore.setAgentSessionUserLabel`); it is read-only on every other path.
    public let userLabel: String?
    public let runtimeTargetID: String?
    public let terminalTarget: TerminalTargetRecord?
    public let sessionKey: String?
    public let claimedLauncherID: String?
    public let claimedLauncherName: String?
    public let status: AgentWindowStatus
    /// Explicit, user-authored annotation for orchestration (`spaces agent annotate`). It is never
    /// derived from prompts or terminal output, and survives status signals — only the annotate path
    /// clears or replaces it.
    public let note: String?
    /// The coding agent kind (claude/codex/opencode) foreground detection classified this session as,
    /// persisted the first time it is observed and refreshed by every later observation. It is stored
    /// rather than read live because the live foreground state it comes from is cleared exactly when the
    /// agent exits, which is when the exited notification has to name the kind. Nil until a kind is
    /// detected, which renders honestly as "coding agent" downstream.
    public let detectedAgentKind: String?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String, workspaceID: String, provider: AgentProvider, label: String?, userLabel: String? = nil, runtimeTargetID: String? = nil,
        terminalTarget: TerminalTargetRecord? = nil, sessionKey: String? = nil, claimedLauncherID: String? = nil, claimedLauncherName: String? = nil,
        status: AgentWindowStatus, note: String? = nil, detectedAgentKind: String? = nil, createdAt: String, updatedAt: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.provider = provider
        self.label = label
        self.userLabel = userLabel
        self.runtimeTargetID = runtimeTargetID
        self.terminalTarget = terminalTarget
        self.sessionKey = sessionKey
        self.claimedLauncherID = claimedLauncherID
        self.claimedLauncherName = claimedLauncherName
        self.status = status
        self.note = note
        self.detectedAgentKind = detectedAgentKind
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
        id: String, workspaceID: String, provider: AgentProvider, label: String?, terminalTrackingID: String?, sessionKey: String?,
        status: AgentWindowStatus, createdAt: String, updatedAt: String
    ) {
        self.init(
            id: id, workspaceID: workspaceID, provider: provider, label: label, runtimeTargetID: nil, terminalTrackingID: terminalTrackingID,
            sessionKey: sessionKey, status: status, createdAt: createdAt, updatedAt: updatedAt)
    }

    public var terminalTrackingID: String? { terminalTarget?.trackingID }

    /// The name this agent answers to: the user's rename when it has one, else the label the agent
    /// reports for itself, and nil when it has neither. This is the name every surface shows and the only
    /// name a name-based lookup or a uniqueness check may read. Reading `label` directly for either
    /// purpose leaves a renamed agent answering to a name nothing displays.
    ///
    /// Claim matching (`AgentLauncherClaim`) is the exception and stays on `label`: it asks which launcher
    /// the agent reported itself as, which a rename does not change.
    public var effectiveLabel: String? {
        if let userLabel = userLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !userLabel.isEmpty { return userLabel }
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        return label
    }

    /// A copy of this record named `userLabel`, so a candidate rename can be run through the workspace's
    /// name-uniqueness check before it is stored.
    public func withUserLabel(_ userLabel: String?) -> AgentWindowRecord {
        AgentWindowRecord(
            id: id, workspaceID: workspaceID, provider: provider, label: label, userLabel: userLabel, runtimeTargetID: runtimeTargetID,
            terminalTarget: terminalTarget, sessionKey: sessionKey, claimedLauncherID: claimedLauncherID, claimedLauncherName: claimedLauncherName,
            status: status, note: note, detectedAgentKind: detectedAgentKind, createdAt: createdAt, updatedAt: updatedAt)
    }
}
