import Foundation

/// A notification line held for a subscriber terminal that was busy when a watched agent transitioned.
/// The `message` is the fully rendered one-line text (deep link included); it carries no reference back
/// to the agent row, so it survives that row's deletion on exit. One row per (subscriber, agent) pair:
/// repeated transitions coalesce onto the same pair, latest state winning.
public struct AgentPendingNotificationRecord: Codable, Sendable, Equatable {
    public let id: String
    public let subscriberTerminalSessionID: String
    public let agentSessionID: String
    public let message: String
    public let createdAt: String

    public init(id: String, subscriberTerminalSessionID: String, agentSessionID: String, message: String, createdAt: String) {
        self.id = id
        self.subscriberTerminalSessionID = subscriberTerminalSessionID
        self.agentSessionID = agentSessionID
        self.message = message
        self.createdAt = createdAt
    }
}
