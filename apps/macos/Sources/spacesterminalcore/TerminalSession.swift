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
}

public struct TerminalSession: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let workspaceID: String?
    public let kind: TerminalSessionKind
    public let title: String
    public let workingDirectory: String
    public let command: String?
    public let shell: String?
    public let ownerClientID: String?
    public let state: TerminalSessionState
    public let createdAt: String
    public let updatedAt: String
    public let exitedAt: String?

    public init(
        id: String = UUID().uuidString, workspaceID: String? = nil, kind: TerminalSessionKind, title: String, workingDirectory: String,
        command: String? = nil, shell: String? = nil, ownerClientID: String? = nil, state: TerminalSessionState, createdAt: String, updatedAt: String,
        exitedAt: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.kind = kind
        self.title = title
        self.workingDirectory = workingDirectory
        self.command = command
        self.shell = shell
        self.ownerClientID = ownerClientID
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.exitedAt = exitedAt
    }
}
