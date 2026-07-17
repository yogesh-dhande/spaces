import Foundation

/// A subscription edge: the terminal session `subscriberTerminalSessionID` watches the agent session
/// `agentSessionID`. The subscriber is keyed by a terminal session id (it may be a plain terminal with
/// no agent row of its own); the target is an agent session id so deleting that agent row cascades the
/// edge away.
public struct AgentSubscriptionRecord: Codable, Sendable, Equatable {
    public let subscriberTerminalSessionID: String
    public let agentSessionID: String
    public let createdAt: String

    public init(subscriberTerminalSessionID: String, agentSessionID: String, createdAt: String) {
        self.subscriberTerminalSessionID = subscriberTerminalSessionID
        self.agentSessionID = agentSessionID
        self.createdAt = createdAt
    }
}
