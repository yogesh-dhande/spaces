import Foundation
import spacesterminalcore

/// Device API request payload for installing Spaces lifecycle hooks for a set of coding agents on the
/// daemon's host. An empty `kinds` list is rejected by the handler.
public struct SpacesDeviceInstallAgentHooksRequest: Codable, Sendable, Equatable {
    public let kinds: [SupportedCodingAgentHook]

    public init(kinds: [SupportedCodingAgentHook]) { self.kinds = kinds }
}

/// Device API result payload carrying the availability + hook-install status of every supported
/// coding agent on the daemon's host. Returned by `agentHooksStatus`.
///
/// `installAgentHooks` answers with `AgentHookInstallOutcome` instead, which carries the same statuses
/// plus the per-agent failures only an install can produce. An install succeeds partially — one
/// agent's uneditable config does not stop the others — so those failures travel alongside the status
/// rather than replacing it with a rejected request.
public struct SpacesAgentHooksStatusPayload: Codable, Sendable, Equatable {
    public let agents: [AgentHookStatus]

    public init(agents: [AgentHookStatus]) { self.agents = agents }
}
