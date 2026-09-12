import Foundation
import spacesterminalcore

/// What this app should offer to bring back, derived from what the active device reports on its daemon
/// status and from the record this client has already answered.
///
/// Pure, so the question of whether there is anything to ask about is decided in one testable place
/// rather than inside the sheet that renders it.
///
/// This is the iOS mirror of the Mac's `SessionRestoreOffer` (`spacesui`), written here for the same
/// reason `DaemonCompatibilityPresentation` is: `spacesui` is an AppKit module this app does not link,
/// and only the wire types the decision reads (`TerminalServiceDaemonStatus`, `RestorableSessionSummary`)
/// are shared. The rules are the Mac's: a device offers its record while it reports one this client has
/// not answered and while it speaks this build's wire version, and a newer capture replaces an older one
/// because it carries a different generation. One device, because this app talks to one device at a
/// time, so the Mac's per-device fan-out has nothing to fan out over here.
struct SessionRestoreOffer: Equatable, Identifiable {
    /// One captured coding-agent session, as the list shows it.
    struct Row: Equatable, Identifiable {
        let sessionID: String
        /// The coding agent the daemon classified the session as, or nil when detection never named one.
        let agentLabel: String?
        let title: String
        let workingDirectory: String
        /// The agent reported no conversation id, so restoring relaunches its original command as a new
        /// conversation. The list says this out loud: it is the one way a restored session differs from
        /// the one it replaces.
        let startsNewConversation: Bool

        var id: String { sessionID }

        /// How the row is worded wherever it is named: in the list, and in the report of what could not
        /// be restored. Shared so the report's line reads like the list entry the user just answered.
        ///
        /// A session Spaces started for an agent is titled after that agent, so naming both would read
        /// "opencode: opencode". The agent's name alone is the whole of what such a row has to say.
        var displayLabel: String {
            guard let agentLabel, agentLabel.caseInsensitiveCompare(title) != .orderedSame else { return title }
            return "\(agentLabel): \(title)"
        }
    }

    /// The rows of one workspace, under the heading the list groups them beneath.
    struct WorkspaceGroup: Equatable, Identifiable {
        let workspaceID: String
        /// What the list puts above the group: the workspace's name when this client has an overview
        /// naming it, and the working directory of the group's first row when it does not (a record can
        /// be reported by the first status of a reconnect, before any overview has landed).
        let heading: String
        let rows: [Row]

        var id: String { workspaceID }
    }

    let deviceID: String
    let deviceName: String
    /// The capture Restore and Skip carry back. Every row of a record shares it, so an answer to an
    /// offer the device has already replaced cannot act on the newer record.
    let generation: String
    let groups: [WorkspaceGroup]

    /// Identity for the sheet that presents this: a newer capture on the same device is a different
    /// question, so it replaces the sheet's content rather than leaving the answered one on screen.
    var id: String { "\(deviceID)/\(generation)" }

    /// The offer to put on screen, or nil when nothing is outstanding (the steady state), and the reason
    /// this returns an optional rather than an empty offer: the caller's first question is whether to
    /// show a sheet at all.
    static func make(
        deviceID: String, deviceName: String, status: TerminalServiceDaemonStatus?, workspaceNamesByID: [String: String] = [:],
        answeredGeneration: String?
    ) -> SessionRestoreOffer? {
        // The record reaches this client through the frozen core of the daemon status, which a daemon of
        // any wire version answers, so it is readable across a release skew that the answer is not: an
        // older daemon would relaunch the agents and clear its record while this app failed to read what
        // came back. Offer nothing until the versions match. Nothing is lost by waiting: the device keeps
        // its record, and the status refresh that reports the updated daemon re-runs this decision.
        guard let status, SpacesWireCompatibility.evaluate(daemonStatus: status).isCompatible else { return nil }
        // The daemon replaces its record wholesale, so every row it reports belongs to one capture and
        // the first row names the generation the answer carries.
        guard let generation = status.restorableSessions.first?.generation, generation != answeredGeneration else { return nil }
        return SessionRestoreOffer(
            deviceID: deviceID, deviceName: deviceName, generation: generation,
            groups: groups(summaries: status.restorableSessions, workspaceNamesByID: workspaceNamesByID))
    }

    /// Whether the offer already on screen survives `status`, which is a different question from whether
    /// a status raises one.
    ///
    /// A question the user is looking at is taken away only by the device saying the record it is about is
    /// gone: it reports no record at all, or it reports a different capture, which is raised in its place.
    /// The two states that say nothing about the record leave it standing: a device that has not reported
    /// (a status fetch that failed, a switch still in progress) and one whose wire version this build
    /// cannot answer across. Withdrawing on either would dismiss the question with no answer given and
    /// nothing said, and for the version gap it would also take away the surface that reports the gap,
    /// since the answer states it in place.
    static func retainsPresentedOffer(presented: SessionRestoreOffer, status: TerminalServiceDaemonStatus?) -> Bool {
        guard let status, SpacesWireCompatibility.evaluate(daemonStatus: status).isCompatible else { return true }
        guard let generation = status.restorableSessions.first?.generation else { return false }
        return generation == presented.generation
    }

    /// Groups the rows by workspace, keeping the order the device reported them in, both for the groups
    /// themselves and within each group, so the list is stable across refreshes.
    private static func groups(summaries: [RestorableSessionSummary], workspaceNamesByID: [String: String]) -> [WorkspaceGroup] {
        var orderedWorkspaceIDs: [String] = []
        var rowsByWorkspaceID: [String: [Row]] = [:]
        for summary in summaries {
            if rowsByWorkspaceID[summary.workspaceID] == nil { orderedWorkspaceIDs.append(summary.workspaceID) }
            rowsByWorkspaceID[summary.workspaceID, default: []].append(
                Row(
                    sessionID: summary.sessionID, agentLabel: summary.agentKind?.displayLabel, title: summary.title,
                    workingDirectory: summary.workingDirectory, startsNewConversation: !summary.hasResumeKey))
        }
        return orderedWorkspaceIDs.compactMap { workspaceID in
            guard let rows = rowsByWorkspaceID[workspaceID], let first = rows.first else { return nil }
            return WorkspaceGroup(workspaceID: workspaceID, heading: workspaceNamesByID[workspaceID] ?? first.workingDirectory, rows: rows)
        }
    }
}
