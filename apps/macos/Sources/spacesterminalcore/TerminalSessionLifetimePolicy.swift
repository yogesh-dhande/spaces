import Foundation

/// The single case stays because the policy is persisted in `terminal_sessions.lifetime_policy`
/// (`TEXT NOT NULL`); dropping the column needs a table rebuild that changes no behavior.
public enum TerminalSessionLifetimePolicy: String, Codable, Sendable, Equatable, CaseIterable {
    case persistent = "persistent"
}
