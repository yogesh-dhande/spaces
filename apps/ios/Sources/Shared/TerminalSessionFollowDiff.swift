import Foundation
import spacesdevicecore
import spacesterminalcore

/// Whether an iOS terminal viewer open on a configured process's session should follow the process onto
/// the session that replaced it. Every restart, from any client, keeps the process's row id and only
/// changes the session the row names, and posts no pane open to any client, so the overview is the only
/// place a viewer learns about the replacement.
///
/// Mirrors the Mac's `TerminalSessionReplacementDiff` recency gate: a replacement must be strictly newer
/// than the session on screen, so a reordered or stale overview can never move the viewer backwards.
/// Unlike the Mac's diff it compares one remembered row against one overview, since the viewer already
/// holds the session it shows and that session's `createdAt`.
enum TerminalSessionFollowDiff {
    /// The configured process row a viewer opened on. The row id is the process's template id, which
    /// every workspace of the project shares, so the workspace id is part of the identity.
    struct ProcessRowIdentity: Equatable {
        let workspaceID: String
        let rowID: String
    }

    /// Nil for anything but a configured process. Reads the wire row's own `id` (the template id), not
    /// `SpacesMobileWorkspaceRuntimeRow.id`, which carries a `process:` prefix that
    /// `workspace.processRows` entries do not.
    static func processRowIdentity(for row: SpacesMobileWorkspaceRuntimeRow) -> ProcessRowIdentity? {
        guard case .process(let processRow) = row.source else { return nil }
        return ProcessRowIdentity(workspaceID: processRow.workspaceID, rowID: processRow.id)
    }

    /// The session the viewer should move to, or nil when it should stay put: the row is gone, still names
    /// the session on screen (including right after the viewer itself swapped), or its session fails the
    /// recency gate.
    static func replacementSession(
        for row: ProcessRowIdentity, displayedSessionID: String, displayedCreatedAt: String, overview: SpacesDeviceOverviewPayload
    ) -> SpacesDeviceTerminalSessionSummary? {
        guard let workspace = overview.workspaces.first(where: { $0.id == row.workspaceID }),
            let processRow = workspace.processRows.first(where: { $0.id == row.rowID }),
            let sessionID = processRow.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty, sessionID != displayedSessionID
        else { return nil }
        guard let candidate = overview.sessions.first(where: { $0.id == sessionID }),
            let candidateCreatedAt = TerminalSessionTimestamp.date(from: candidate.createdAt)
        else { return nil }
        // The displayed session's createdAt is allowed to fail to parse (it never should, but a
        // malformed value must not block a genuine forward move); only the candidate's own createdAt is
        // required, mirroring `TerminalSessionReplacementDiff`'s "replaced side optional, replacement side
        // required" rule and its reasoning.
        if let displayedCreatedAtDate = TerminalSessionTimestamp.date(from: displayedCreatedAt), candidateCreatedAt <= displayedCreatedAtDate {
            return nil
        }
        return candidate
    }
}
