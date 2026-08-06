import Foundation

/// Which live coding agents a workspace's configured launchers have claimed.
///
/// A claimed agent is shown by its launcher's row and is named by that launcher's config entry, so
/// nothing else may name it: a rename must edit the launcher entry, not the agent session.
public struct AgentLauncherClaims: Sendable, Equatable {
    /// The agent each configured launcher shows, keyed by launcher id. A launcher with no live agent has
    /// no entry, and one agent can appear under more than one launcher when a second launcher's name
    /// matches an agent that a first launcher already claimed by id.
    public let agentIDByLauncherID: [String: String]
    /// Every agent some configured launcher shows.
    public let claimedAgentIDs: Set<String>

    public init(agentIDByLauncherID: [String: String], claimedAgentIDs: Set<String>) {
        self.agentIDByLauncherID = agentIDByLauncherID
        self.claimedAgentIDs = claimedAgentIDs
    }
}

/// The single definition of when a configured agent launcher claims a live coding agent. The device
/// overview builds its configured agent rows from this, and the agent-session rename refuses a claimed
/// agent from it, so the two can never disagree about which name a row answers to.
///
/// This is deliberately not `WorkspaceOrchestrator.spacesAgentRecordIsConfiguredLauncher`, which asks a
/// different question (may this record be restarted through its launcher) with different rules.
public enum AgentLauncherClaim {
    /// Names match once trimmed, case-insensitively and diacritic-insensitively, the same folding
    /// `normalizedFocusName` applies. A launcher and an agent whose names differ only in casing, accents,
    /// or surrounding whitespace are one row to a user, so they must be one row here: two normalizers
    /// would let a row be claimed by one rule and named by the other.
    public static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Resolves the claims for one workspace. `agents` must be in store order: when two agents would
    /// claim the same launcher, the first one wins and the rest stay unclaimed, so a second agent that
    /// happens to report a configured launcher's name keeps its own row and stays renameable.
    ///
    /// An agent claims by id when it carries a non-empty `claimedLauncherID`, and by name otherwise,
    /// using the first non-empty name it reports (`claimedLauncherName`, else `label`). A launcher whose
    /// name is empty shows no row and claims nothing.
    public static func resolve(agents: [AgentWindowRecord], launchers: [AgentLauncher]) -> AgentLauncherClaims {
        let agentByClaimedLauncherID = Dictionary(
            agents.compactMap { agent -> (String, AgentWindowRecord)? in
                guard let id = agent.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
                return (id, agent)
            }, uniquingKeysWith: { existing, _ in existing })
        let agentByReportedName = Dictionary(
            agents.compactMap { agent -> (String, AgentWindowRecord)? in
                guard agent.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return nil }
                let names = [agent.claimedLauncherName, agent.label].compactMap { $0 }.map(normalizedName).filter { !$0.isEmpty }
                guard let name = names.first else { return nil }
                return (name, agent)
            }, uniquingKeysWith: { existing, _ in existing })

        var agentIDByLauncherID: [String: String] = [:]
        var claimedAgentIDs = Set<String>()
        for launcher in launchers {
            let name = normalizedName(launcher.name)
            guard !name.isEmpty else { continue }
            guard let agent = agentByClaimedLauncherID[launcher.id] ?? agentByReportedName[name] else { continue }
            agentIDByLauncherID[launcher.id] = agent.id
            claimedAgentIDs.insert(agent.id)
        }
        return AgentLauncherClaims(agentIDByLauncherID: agentIDByLauncherID, claimedAgentIDs: claimedAgentIDs)
    }
}
