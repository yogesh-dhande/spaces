import Foundation

/// One searchable utterance: what the user typed or what the agent replied. Tool calls and results,
/// reasoning, images and context the agent injected on its own are never messages.
public struct AgentSessionMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String
    public let timestamp: Date?
    /// The folded child session (an opencode subagent's) the message was written in; nil for the read's own
    /// transcript. Each origin forms its own turns, so a child's prompt never splits the parent's turn.
    public let originSessionID: String?

    public init(role: Role, text: String, timestamp: Date?, originSessionID: String? = nil) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.originSessionID = originSessionID
    }
}
