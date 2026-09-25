/// Whether each coding agent's brief column is shown, as the user last left it.
///
/// Keyed by the agent (`row.agentID ?? row.id`), never by the session: a restart replaces the agent's
/// session, and the user's choice belongs to the agent, not to whichever session it runs in. In memory
/// only, so a relaunch shows every brief again. An agent with no entry shows its brief whenever it has
/// one; a toggle records the explicit choice.
struct AgentBriefVisibility {
    private var shownByAgentKey: [String: Bool] = [:]

    /// The toggle state of `agentKey`'s brief, given the brief the agent currently has.
    func state(agentKey: String, brief: String?) -> AgentBriefToggleState {
        guard brief != nil else { return .unavailable }
        return (shownByAgentKey[agentKey] ?? true) ? .shown : .hidden
    }

    /// Flips `agentKey`'s brief between shown and hidden. An agent with no brief has nothing to flip,
    /// so its next brief still shows by itself.
    mutating func toggle(agentKey: String, brief: String?) {
        switch state(agentKey: agentKey, brief: brief) {
        case .unavailable: return
        case .shown: shownByAgentKey[agentKey] = false
        case .hidden: shownByAgentKey[agentKey] = true
        }
    }
}
