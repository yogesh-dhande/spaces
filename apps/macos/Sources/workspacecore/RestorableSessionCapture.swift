import Foundation
import spacesterminalcore

/// What the database knows about one coding-agent session that could be brought back, read straight off
/// its `terminal_sessions` and `agent_sessions` rows. A capture becomes a `RestorableSessionRecord` when
/// it is written into `restorable_sessions` under a generation.
///
/// Only sessions that carry a raw launch command are ever captured: without it there is nothing to
/// relaunch, so an agent whose session predates that column is simply not offered.
public struct RestorableSessionCapture: Sendable, Equatable {
    public let sessionID: String
    public let workspaceID: String
    public let agentKind: TerminalDetectedAgentKind?
    public let agentSessionKey: String?
    public let launchCommand: String
    public let workingDirectory: String
    public let title: String

    public init(
        sessionID: String, workspaceID: String, agentKind: TerminalDetectedAgentKind?, agentSessionKey: String?, launchCommand: String,
        workingDirectory: String, title: String
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.agentKind = agentKind
        self.agentSessionKey = agentSessionKey
        self.launchCommand = launchCommand
        self.workingDirectory = workingDirectory
        self.title = title
    }

    public func record(generation: String, capturedAt: String) -> RestorableSessionRecord {
        RestorableSessionRecord(
            sessionID: sessionID, generation: generation, workspaceID: workspaceID, agentKind: agentKind, agentSessionKey: agentSessionKey,
            launchCommand: launchCommand, workingDirectory: workingDirectory, title: title, capturedAt: capturedAt)
    }
}
