import Foundation

/// A cross-device watch edge: the local terminal session `subscriberTerminalSessionID` watches a
/// coding-agent session living on the paired device `deviceID`. `agentSessionID` holds the watched
/// child's **terminal session id** on that device — the stable cross-device handle the user addresses and
/// the notification's deep link targets, and the key the watch service diffs `listAgentSessions` rows
/// against. Unlike `AgentSubscriptionRecord`, the target is not a local agent row — it is an agent on
/// another device's database — so this edge has no foreign key and its lifecycle is driven by the remote
/// watch service, which delivers the terminating line and drops the edge when the remote agent exits.
public struct AgentRemoteSubscriptionRecord: Codable, Sendable, Equatable {
    public let subscriberTerminalSessionID: String
    public let deviceID: String
    public let agentSessionID: String
    public let createdAt: String

    public init(subscriberTerminalSessionID: String, deviceID: String, agentSessionID: String, createdAt: String) {
        self.subscriberTerminalSessionID = subscriberTerminalSessionID
        self.deviceID = deviceID
        self.agentSessionID = agentSessionID
        self.createdAt = createdAt
    }
}
