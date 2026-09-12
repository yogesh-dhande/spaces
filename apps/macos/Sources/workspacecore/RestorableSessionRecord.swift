import Foundation
import spacesterminalcore

/// One `restorable_sessions` row: a coding-agent session that ended with its work unfinished, captured
/// with everything the daemon needs to bring it back: the raw command it was launched with, the
/// conversation id its provider can resume, and where it ran.
///
/// A record is only ever written as part of a whole generation (see
/// `SQLiteStore.replaceRestorableSessions(generation:rows:)`), so every row a client sees shares one
/// `generation` value and Restore or Skip can be matched against it.
public struct RestorableSessionRecord: Sendable, Equatable {
    /// The terminal session the agent ran in. Primary key, so re-capturing the same session replaces
    /// rather than duplicates it.
    public let sessionID: String
    public let generation: String
    public let workspaceID: String
    /// The coding agent this session was classified as, or nil when detection never named one.
    public let agentKind: TerminalDetectedAgentKind?
    /// The agent's own conversation id, reported by its hooks. Nil means the relaunch starts fresh.
    public let agentSessionKey: String?
    /// The raw command the agent was spawned with, before the login-shell and environment wrapping.
    public let launchCommand: String
    public let workingDirectory: String
    public let title: String
    public let capturedAt: String

    public init(
        sessionID: String, generation: String, workspaceID: String, agentKind: TerminalDetectedAgentKind?, agentSessionKey: String?,
        launchCommand: String, workingDirectory: String, title: String, capturedAt: String
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.workspaceID = workspaceID
        self.agentKind = agentKind
        self.agentSessionKey = agentSessionKey
        self.launchCommand = launchCommand
        self.workingDirectory = workingDirectory
        self.title = title
        self.capturedAt = capturedAt
    }

    /// The client-facing half of this row. The launch command and the conversation id stay on the daemon,
    /// which is the only party that relaunches anything; a client is told only whether a key exists.
    public var summary: RestorableSessionSummary {
        RestorableSessionSummary(
            sessionID: sessionID, workspaceID: workspaceID, agentKind: agentKind, title: title, workingDirectory: workingDirectory,
            hasResumeKey: agentSessionKey?.isEmpty == false, generation: generation)
    }
}
