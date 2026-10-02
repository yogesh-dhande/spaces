import Foundation
import spacesdevicecore
import spacesterminalcore

/// The three alert mutations. Each decides against `overview`, the daemon's own freshly built overview
/// (hidden workspaces included), never against what a client last saw.
///
/// Stored state is pruned here and only here: a dismissal whose alert is no longer a candidate of
/// `overview`, and a flag whose row `overview` no longer lists, are deleted. A flag left behind would
/// come back on a process row whose id returns (a configured process row is keyed by its configured process id). A plain overview build never prunes, because a transiently incomplete overview
/// (a session list mid-refresh) would otherwise delete dismissals whose alerts come right back.
extension WorkspaceOrchestrator {
    public func dismissAlerts(keys: [String], in overview: SpacesDeviceOverviewPayload) throws {
        let candidateKeys = Set(overview.alertCandidates().map(\.key))
        var dismissing: [String] = []
        var clearingFlags: [(rowKind: SpacesDeviceComeBackLaterRowKind, rowID: String)] = []
        for key in keys {
            if let row = SpacesDeviceComeBackLaterFlag.rowReference(fromAlertKey: key) {
                clearingFlags.append(row)
            } else if candidateKeys.contains(key) {
                dismissing.append(key)
            }
        }
        try applyAlertStateChange(dismissing: dismissing, clearingFlags: clearingFlags, candidateKeys: candidateKeys)
    }

    /// A visit dismisses the done/exited alerts of the session and clears the flags on its rows, but only
    /// those the client names in `keys`: the keys whose own dwell completed. A key the client has not
    /// named (a mark first seen mid-visit, or one it has not received yet) is never touched, whatever
    /// the request's latency. A named flag is also cleared only if it was set before the visit began, which
    /// covers a mark removed and set again during the visit under the same key. The start is derived from
    /// `focusedForSeconds` on this daemon's clock, so a client's clock never enters the comparison with
    /// `flaggedAt`.
    public func visitTerminalSession(
        sessionID: String, focusedForSeconds: Double, keys: [String], in overview: SpacesDeviceOverviewPayload, now: Date = Date()
    ) throws {
        guard focusedForSeconds.isFinite, focusedForSeconds >= 0 else {
            throw WorkspaceError.invalidArgument(message: "focusedForSeconds must be a non-negative number.")
        }
        let visitStart = now.addingTimeInterval(-focusedForSeconds)
        let candidates = overview.alertCandidates()
        let named = Set(keys)
        let dismissing = candidates.filter { $0.sessionID == sessionID && $0.clearsOnVisit && named.contains($0.key) }.map(\.key)
        let clearingFlags = overview.comeBackLaterFlags.filter { flag in
            guard named.contains(flag.alertKey),
                let row = SpacesDeviceOverviewPayload.comeBackLaterRow(for: flag, in: overview.workspaces), row.sessionID == sessionID,
                let flaggedAt = GhosttyRemoteSessionStateTimestamp.date(from: flag.flaggedAt)
            else { return false }
            // Backstop for a mark re-set on another device while the visit keeps seeing the same key; only
            // there is it sensitive to request latency, since clients never name a mark they saw
            // disappear or first saw mid-visit (accepted).
            return flaggedAt < visitStart
        }.map { (rowKind: $0.rowKind, rowID: $0.rowID) }
        try applyAlertStateChange(dismissing: dismissing, clearingFlags: clearingFlags, candidateKeys: Set(candidates.map(\.key)))
    }

    public func setComeBackLater(
        rowKind: SpacesDeviceComeBackLaterRowKind, rowID: String, isOn: Bool, in overview: SpacesDeviceOverviewPayload, now: Date = Date()
    ) throws {
        let candidateKeys = Set(overview.alertCandidates().map(\.key))
        guard isOn else {
            try applyAlertStateChange(dismissing: [], clearingFlags: [(rowKind, rowID)], candidateKeys: candidateKeys)
            return
        }
        let flag = SpacesDeviceComeBackLaterFlag(rowKind: rowKind, rowID: rowID, flaggedAt: "")
        guard SpacesDeviceOverviewPayload.comeBackLaterRow(for: flag, in: overview.workspaces) != nil else {
            throw WorkspaceError.invalidArgument(message: "No \(rowKind.rawValue) row '\(rowID)' to flag.")
        }
        // A process that has never started has no session to visit, so nothing could ever clear its flag.
        if rowKind == .process, let process = overview.workspaces.lazy.flatMap(\.processRows).first(where: { $0.id == rowID }),
            process.runState == .notStarted, process.sessionID == nil
        {
            throw WorkspaceError.invalidArgument(message: "Process '\(rowID)' has not started, so there is nothing to come back to.")
        }
        try store.setComeBackLaterFlag(rowKind: rowKind, rowID: rowID, flaggedAt: GhosttyRemoteSessionStateTimestamp.string(from: now))
        // `overview` predates this flag, so its key is added or the prune below would delete it at once.
        try applyAlertStateChange(dismissing: [], clearingFlags: [], candidateKeys: candidateKeys.union([flag.alertKey]))
    }

    private func applyAlertStateChange(
        dismissing: [String], clearingFlags: [(rowKind: SpacesDeviceComeBackLaterRowKind, rowID: String)], candidateKeys: Set<String>
    ) throws {
        let storedDismissals = try store.alertDismissalKeys()
        let storedFlags = try store.comeBackLaterFlags()
        let storedFlagKeys = Set(storedFlags.map(\.alertKey))
        let newDismissals = dismissing.filter { !storedDismissals.contains($0) }
        let clearingKeys = Set(clearingFlags.map { SpacesDeviceComeBackLaterFlag.alertKey(rowKind: $0.rowKind, rowID: $0.rowID) })
        let staleFlags = storedFlags.filter { !candidateKeys.contains($0.alertKey) && !clearingKeys.contains($0.alertKey) }
        let flagsToClear =
            clearingFlags.filter { storedFlagKeys.contains(SpacesDeviceComeBackLaterFlag.alertKey(rowKind: $0.rowKind, rowID: $0.rowID)) }
            + staleFlags.map { (rowKind: $0.rowKind, rowID: $0.rowID) }
        let stale = storedDismissals.filter { !candidateKeys.contains($0) }
        guard !newDismissals.isEmpty || !flagsToClear.isEmpty || !stale.isEmpty else { return }
        try store.applyAlertStateChange(
            dismissing: newDismissals, dismissedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()), clearingFlags: flagsToClear,
            pruning: Array(stale))
    }
}
