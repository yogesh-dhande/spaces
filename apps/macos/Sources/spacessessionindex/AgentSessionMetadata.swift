import Foundation

/// What one read learned about a session beyond its messages.
///
/// An incremental read starts mid-file and cannot see what earlier reads saw (a Codex session's working
/// directory is only on its first line), so a read reports only what it observed and the caller folds the
/// result into what it already holds with `merging(_:)`.
public struct AgentSessionMetadata: Sendable, Equatable {
    /// The agent's own title for the session, when it records one.
    public var title: String?
    public var workingDirectory: String?
    /// The first thing the user typed, the title shown when the agent records none.
    public var firstUserPrompt: String?
    public var lastActivity: Date?
    /// True for a non-interactive run (`claude -p`, `codex exec`, `codex review`, `opencode run`), which is
    /// not indexed.
    public var isOneShot: Bool

    public init(
        title: String? = nil, workingDirectory: String? = nil, firstUserPrompt: String? = nil, lastActivity: Date? = nil, isOneShot: Bool = false
    ) {
        self.title = title
        self.workingDirectory = workingDirectory
        self.firstUserPrompt = firstUserPrompt
        self.lastActivity = lastActivity
        self.isOneShot = isOneShot
    }

    /// Folds a later read into this one. The working directory and first prompt are where the session
    /// began, so the earlier value stays; a title is replaced when the agent records a new one; a session
    /// that was ever seen to be a one-shot run stays one.
    public func merging(_ later: AgentSessionMetadata) -> AgentSessionMetadata {
        AgentSessionMetadata(
            title: later.title ?? title, workingDirectory: workingDirectory ?? later.workingDirectory,
            firstUserPrompt: firstUserPrompt ?? later.firstUserPrompt, lastActivity: [lastActivity, later.lastActivity].compactMap { $0 }.max(),
            isOneShot: isOneShot || later.isOneShot)
    }
}
