import Foundation

public enum TerminalSessionKind: String, Codable, Sendable, CaseIterable {
    case shell
    case process
    case agent
    /// A workspace-bound session that runs a scheduled automation's command. Kept distinct from `.agent`,
    /// which is load-bearing for the coding-agent subscription graph and signal chokepoint; an automation
    /// session must not be mistaken for a coding agent.
    case automation
}

public enum TerminalSessionState: String, Codable, Sendable, CaseIterable {
    case starting
    case running
    case exited
    case failed

    public var isInteractive: Bool { self == .starting || self == .running }
}
