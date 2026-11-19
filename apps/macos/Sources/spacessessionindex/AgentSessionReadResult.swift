import Foundation

/// Where the next read of a file or session picks up.
public enum AgentSessionResumeState: Sendable, Equatable {
    /// Append-only JSONL: the offset just past the last complete line read. A partial trailing line is
    /// never consumed, so the next read re-reads it once the writer has finished it.
    case byteOffset(Int64)
    /// opencode: the latest `time_updated` among the rows read. The next read takes rows updated after it.
    case watermark(Int64)
    /// Whole-file JSON, a metadata sidecar or an immutable compressed file: nothing to resume, because the
    /// content was read in full.
    case complete
}

/// What one read of a file (or of an opencode session) produced.
public struct AgentSessionReadResult: Sendable, Equatable {
    public let messages: [AgentSessionMessage]
    public let metadata: AgentSessionMetadata
    public let nextState: AgentSessionResumeState

    public init(messages: [AgentSessionMessage], metadata: AgentSessionMetadata, nextState: AgentSessionResumeState) {
        self.messages = messages
        self.metadata = metadata
        self.nextState = nextState
    }
}
