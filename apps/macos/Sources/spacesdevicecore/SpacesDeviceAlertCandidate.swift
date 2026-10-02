import Foundation

public enum SpacesDeviceAlertKind: String, Sendable, Equatable, Hashable {
    case agentWaiting
    case agentDone
    case processExited
    case terminalExited
    case terminalFailed
    case bell
    case automationRunFailed
    case automationRunTimedOut
    case comeBackLater

    /// Whether the user staying on the alert's terminal dismisses it. Waiting agents, bells, automation
    /// runs, and flags are excluded: they need an answer or a later look that merely watching the
    /// terminal does not give.
    public var clearsOnVisit: Bool {
        switch self {
        case .agentDone, .processExited, .terminalExited, .terminalFailed: true
        case .agentWaiting, .bell, .automationRunFailed, .automationRunTimedOut, .comeBackLater: false
        }
    }
}

/// One thing that could alert the user, derived from a device overview (see `SpacesDeviceAlerts`).
/// Visibility, focus, and dismissal are the consumer's concern; a candidate exists for every source in
/// the overview's state, hidden workspaces included.
public struct SpacesDeviceAlertCandidate: Sendable, Equatable, Identifiable {
    /// Canonical, device-free identity: the same source in the same state at the same time keeps its key
    /// across refreshes and clients, and a new state change mints a new one.
    public let key: String
    public let kind: SpacesDeviceAlertKind
    /// Nil only for automation runs, which belong to no workspace.
    public let workspaceID: String?
    /// The terminal session the source shows, if any.
    public let sessionID: String?
    /// The agent, process, or terminal row id; the session id for a loose session or bell; the run id for
    /// an automation run.
    public let subjectID: String
    public let date: Date?

    public var id: String { key }
    public var clearsOnVisit: Bool { kind.clearsOnVisit }

    public init(key: String, kind: SpacesDeviceAlertKind, workspaceID: String?, sessionID: String?, subjectID: String, date: Date?) {
        self.key = key
        self.kind = kind
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.subjectID = subjectID
        self.date = date
    }
}
