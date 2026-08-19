import Foundation
import spacesdevicecore
import spacesterminalcore

/// Which of a device's runtime targets swapped the terminal session they track between two consecutive
/// overviews of that device.
///
/// This is how a client learns that a pane should be pointed at a replacement rather than closed. The
/// replacement's own open would say so directly, but every start and restart of a runtime target is
/// served by the Device API, whose orchestrator has no opener to any client (see
/// `SpacesDeviceAPIServer.deviceOrchestrator`), so that message is never posted. The overview carries the
/// same fact: a restart keeps the target's row and only changes the session id the row names.
///
/// Overviews for a remote device do not always arrive in the order they were produced: a subscription
/// push can land while an older pull that snapshotted pre-restart state is still in flight, and that
/// pull's result applies afterwards. Read naively as "previous then current", such a stale overview looks
/// exactly like a restart running in reverse: the row now names the pre-restart session A again, which
/// reads as a replacement of the just-applied live session B by A. Repointing the pane at A would hand it
/// back to a session that has already been replaced (and is likely already terminated). Gating each
/// pairing on `SpacesDeviceTerminalSessionSummary.createdAt` closes this: a genuine replacement is always
/// younger than what it replaced, so a candidate whose replacement is not strictly newer is rejected as a
/// reordering artifact rather than emitted. The replaced session's createdAt is allowed to be unknown,
/// because the ordinary forward case of starting a target whose previous run already exited has nothing
/// to compare, since the exited session has already dropped out of the overview's `sessions` array; only
/// the replacement side's createdAt must be known, both to have a value to compare against and because a
/// stale overview following an exited-start has no live session for the "replacement" id to resolve
/// either, so requiring it closes that reordering case too. The cost of requiring a known replacement is
/// a replacement that exits before the first overview naming it (an instant crash within one refresh):
/// that pairing is never emitted, and the old pane closes through the normal pruning path instead of
/// being reused, which is the behavior every case had before this gate existed.
///
/// Session `createdAt` is stamped with sub-second precision (`TerminalSessionTimestamp.fractionalString`)
/// specifically so a rapid restart never produces two sessions whose createdAt compares equal: this gate
/// treats `replacementCreated <= replacedCreated` as a rejection, so an equal stamp would silently drop a
/// legitimate same-second pairing. Because of that precision, an equal (or reversed) comparison here means
/// the overview is stale or reordered, not that two sessions were genuinely created together.
enum TerminalSessionReplacementDiff {
    struct Replacement: Equatable {
        let workspaceID: String
        let replacedSessionID: String
        let replacementSessionID: String
    }

    /// Rows are keyed by workspace as well as by row id: a configured process row is identified by its
    /// `spaces.yaml` template id, which every workspace of the project shares, so a row id alone would
    /// pair one workspace's ended session with another workspace's replacement.
    private struct RowKey: Hashable {
        let workspaceID: String
        let rowID: String
    }

    /// Only a row present in both overviews with two different sessions yields a replacement. A row that
    /// disappeared is a runtime entry that was removed, whose pane must close rather than move, and a row
    /// that gained its first session is a target starting fresh with no pane to inherit.
    static func replacements(previous: SpacesDeviceOverviewPayload?, current: SpacesDeviceOverviewPayload) -> [Replacement] {
        guard let previous else { return [] }
        let previousSessionIDs = trackedSessionIDsByRow(previous)
        guard !previousSessionIDs.isEmpty else { return [] }
        let previousCreatedAt = createdAtBySessionID(previous)
        let currentCreatedAt = createdAtBySessionID(current)
        var replacements: [Replacement] = []
        for (key, replacementSessionID) in trackedSessionIDsByRow(current) {
            guard let replacedSessionID = previousSessionIDs[key], replacedSessionID != replacementSessionID else { continue }
            // The replacement's createdAt must be known and not older than the replaced session's. See
            // the type-level doc comment for why each side of this comparison is required.
            //
            // Accepted risk: a daemon that stamps whole-second `createdAt` (one predating the fractional
            // stamps introduced alongside this diff) can give a same-second restart two equal timestamps,
            // which this `<=` rejects, closing the predecessor pane instead of reusing it (the behavior
            // the product had before pane reuse existed; the next open self-heals). Every daemon build
            // carrying this diff also carries the fractional stamps, so the case needs a mixed install
            // with a pre-reuse daemon, and no such daemons are deployed. No compat path is added for it.
            guard let replacementCreated = currentCreatedAt[replacementSessionID] else { continue }
            if let replacedCreated = previousCreatedAt[replacedSessionID], replacementCreated <= replacedCreated { continue }
            replacements.append(
                Replacement(workspaceID: key.workspaceID, replacedSessionID: replacedSessionID, replacementSessionID: replacementSessionID))
        }
        // Dictionary iteration order is not stable across runs, and the caller mutates panel layouts.
        return replacements.sorted { ($0.workspaceID, $0.replacedSessionID) < ($1.workspaceID, $1.replacedSessionID) }
    }

    /// `createdAt` for every session an overview currently lists. A session that has exited has already
    /// dropped out of `sessions`, so it is simply absent here rather than mapped to a value.
    private static func createdAtBySessionID(_ overview: SpacesDeviceOverviewPayload) -> [String: Date] {
        var createdAt: [String: Date] = [:]
        for session in overview.sessions {
            guard let date = TerminalSessionTimestamp.date(from: session.createdAt) else { continue }
            createdAt[session.id] = date
        }
        return createdAt
    }

    private static func trackedSessionIDsByRow(_ overview: SpacesDeviceOverviewPayload) -> [RowKey: String] {
        var tracked: [RowKey: String] = [:]
        func record(workspaceID: String, rowID: String, sessionID: String?) {
            guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else { return }
            tracked[RowKey(workspaceID: workspaceID, rowID: rowID)] = sessionID
        }
        for workspace in overview.workspaces {
            for row in workspace.processRows { record(workspaceID: workspace.id, rowID: row.id, sessionID: row.sessionID) }
            for row in workspace.codingAgentRows { record(workspaceID: workspace.id, rowID: row.id, sessionID: row.sessionID) }
            for row in workspace.terminalRows { record(workspaceID: workspace.id, rowID: row.id, sessionID: row.sessionID) }
        }
        return tracked
    }
}
