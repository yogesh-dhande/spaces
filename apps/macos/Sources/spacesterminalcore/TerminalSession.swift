import Foundation

public enum TerminalSessionKind: String, Codable, Sendable, CaseIterable {
    case shell
    case process
    case agent
}

public enum TerminalSessionState: String, Codable, Sendable, CaseIterable {
    case starting
    case running
    case exited
    case failed

    public var isInteractive: Bool { self == .starting || self == .running }
}
