import Foundation
import spacesterminalcore

/// The persisted identity of a terminal session stamped with an automation run id. It is what describes an
/// attributed session once nothing else does — the live pane is gone and the orchestration agent row has
/// been finalized away — leaving the `terminal_sessions` row as the only source for what the run's retained
/// replay holds.
public struct AutomationAttributedSession: Sendable, Equatable {
    public let sessionID: String
    public let kind: TerminalSessionKind
    /// The session's stable name: the user's rename when one is stored, else the launch title.
    public let name: String
    /// The workspace the attributed session ran in.
    public let workspaceID: String?

    public init(sessionID: String, kind: TerminalSessionKind, name: String, workspaceID: String?) {
        self.sessionID = sessionID
        self.kind = kind
        self.name = name
        self.workspaceID = workspaceID
    }
}
