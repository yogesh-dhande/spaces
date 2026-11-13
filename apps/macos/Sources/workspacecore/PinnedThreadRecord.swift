import Foundation

/// A pinned thread as stored: a named coding-agent conversation of one workspace that outlives the agent
/// row running it. `launchCommand` and `workingDirectory` are what resumes the conversation, captured when
/// the pin was made.
public struct PinnedThreadRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let workspaceID: String
    /// The conversation id the pin holds, unique within the workspace.
    public let sessionKey: String
    /// The pin's name. While an agent row is attached the row's `userLabel` equals it.
    public let name: String
    public let launchCommand: String
    public let workingDirectory: String
    /// The agent row currently running the conversation, nil while the pin is not running.
    public let agentSessionID: String?
    public let pinnedAt: String
    /// The brief saved for the conversation, read from `agent_conversation_briefs`.
    public let brief: String?
    public let briefUpdatedAt: String?

    public init(
        id: String, workspaceID: String, sessionKey: String, name: String, launchCommand: String, workingDirectory: String,
        agentSessionID: String? = nil, pinnedAt: String, brief: String? = nil, briefUpdatedAt: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.sessionKey = sessionKey
        self.name = name
        self.launchCommand = launchCommand
        self.workingDirectory = workingDirectory
        self.agentSessionID = agentSessionID
        self.pinnedAt = pinnedAt
        self.brief = brief
        self.briefUpdatedAt = briefUpdatedAt
    }

    public func withName(_ name: String) -> PinnedThreadRecord {
        PinnedThreadRecord(
            id: id, workspaceID: workspaceID, sessionKey: sessionKey, name: name, launchCommand: launchCommand, workingDirectory: workingDirectory,
            agentSessionID: agentSessionID, pinnedAt: pinnedAt, brief: brief, briefUpdatedAt: briefUpdatedAt)
    }
}
