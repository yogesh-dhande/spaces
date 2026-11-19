import Foundation
import spacesterminalcore

/// One resumable session found in an agent's store, described from stat information alone.
public struct AgentSessionSource: Sendable, Hashable {
    public let agent: CodingAgent
    /// The session's identity within its agent; stable across refreshes.
    public let id: String
    /// The key `CodingAgent.resumeCommand(launchCommand:sessionKey:)` expects for this agent: the session
    /// id for Claude Code, Codex, opencode and Copilot, the thread id for Amp, and the transcript file's
    /// path for pi.
    public let sessionKey: String
    /// Every file that carries the session's content, the main transcript first, then folded subagent
    /// transcripts. Empty for opencode, whose sessions are rows of one database.
    public let files: [AgentSessionFile]
    /// Bytes the session occupies: its files' sizes, including folded subagent transcripts, or for
    /// opencode the bytes of its message and part rows, including folded child sessions.
    public let sizeBytes: Int64
    /// The latest modification across the session's files, or the latest `time_updated` among an opencode
    /// session and its children.
    public let lastModified: Date

    public init(agent: CodingAgent, id: String, sessionKey: String, files: [AgentSessionFile], sizeBytes: Int64, lastModified: Date) {
        self.agent = agent
        self.id = id
        self.sessionKey = sessionKey
        self.files = files
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
    }

    /// A file-backed session: size and modification time are derived from `files`.
    init(agent: CodingAgent, id: String, sessionKey: String, files: [AgentSessionFile]) {
        self.init(
            agent: agent, id: id, sessionKey: sessionKey, files: files, sizeBytes: files.reduce(0) { $0 + $1.size },
            lastModified: files.map(\.modifiedAt).max() ?? .distantPast)
    }
}
