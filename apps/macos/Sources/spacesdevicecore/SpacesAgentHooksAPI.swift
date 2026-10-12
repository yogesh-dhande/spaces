import Foundation
import spacesterminalcore

/// Device API request payload for installing Spaces lifecycle hooks for a set of coding agents on the
/// daemon's host. An empty `kinds` list is rejected by the handler.
public struct SpacesDeviceInstallAgentHooksRequest: Codable, Sendable, Equatable {
    public let kinds: [CodingAgent]

    public init(kinds: [CodingAgent]) { self.kinds = kinds }

    /// Kinds this build does not know are dropped (see `SkippingUnreadableList`): a newer client asking
    /// an older daemon to install an agent it lacks still gets the others installed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kinds = try container.decodeSkippingUnreadable(CodingAgent.self, forKey: .kinds)
    }
}

/// Device API request payload for recording an agent's trust in the Spaces hooks installed on the
/// daemon's host. The daemon trusts only the entries it would write itself, never what a client names,
/// so the request carries the agent and nothing else.
public struct SpacesDeviceTrustAgentHooksRequest: Codable, Sendable, Equatable {
    public let kind: CodingAgent

    public init(kind: CodingAgent) { self.kind = kind }
}

/// Device API result payload carrying the availability + hook-install status of every supported
/// coding agent on the daemon's host. Returned by `agentHooksStatus`.
///
/// `installAgentHooks` and `trustAgentHooks` answer with `AgentHookInstallOutcome` instead, which
/// carries the same statuses plus the per-agent failures only those requests can produce. An install
/// succeeds partially (one agent's uneditable config does not stop the others), and a trust the agent
/// refuses still leaves fresh status worth showing, so those failures travel alongside the status rather
/// than replacing it with a rejected request.
public struct SpacesAgentHooksStatusPayload: Codable, Sendable, Equatable {
    public let agents: [AgentHookStatus]

    public init(agents: [AgentHookStatus]) { self.agents = agents }

    /// Rows naming an agent this build does not know are dropped (see `SkippingUnreadableList`), so a
    /// newer daemon's status still lists the agents this client can show.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = try container.decodeSkippingUnreadable(AgentHookStatus.self, forKey: .agents)
    }
}
