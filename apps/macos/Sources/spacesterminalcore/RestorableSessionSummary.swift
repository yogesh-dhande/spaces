import Foundation

/// One coding-agent session a device is offering to bring back, as it reaches a client on
/// `TerminalServiceDaemonStatus`. The daemon captures these rows when a clean Stop All and Quit parks
/// its live agents, and when it starts up to find agent sessions stranded by an unclean exit.
///
/// This is the client-facing half of a `restorable_sessions` row: the command to relaunch and the
/// agent's conversation id stay on the daemon, because a client never composes the relaunch itself: it
/// answers Restore or Skip, and the daemon does the rest. `hasResumeKey` is what a client needs from
/// the key: `false` means the relaunch starts a new conversation, which the offer says out loud.
public struct RestorableSessionSummary: Codable, Sendable, Equatable {
    /// The terminal session the agent ran in before it ended. Identifies the row to a client that wants
    /// to put the restored agent back where the old one was.
    public let sessionID: String
    public let workspaceID: String
    /// The coding agent the daemon had classified this session as, or nil when detection never named one.
    public let agentKind: TerminalDetectedAgentKind?
    public let title: String
    public let workingDirectory: String
    /// Whether the agent reported a conversation id its provider can resume. Without one, restoring
    /// relaunches the original command as a new conversation.
    public let hasResumeKey: Bool
    /// The capture pass this row belongs to. Every row of one record shares it, and Restore and Skip
    /// carry it back so a click on a stale offer cannot act on a newer record.
    public let generation: String

    public init(
        sessionID: String, workspaceID: String, agentKind: TerminalDetectedAgentKind?, title: String, workingDirectory: String, hasResumeKey: Bool,
        generation: String
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.agentKind = agentKind
        self.title = title
        self.workingDirectory = workingDirectory
        self.hasResumeKey = hasResumeKey
        self.generation = generation
    }
}
