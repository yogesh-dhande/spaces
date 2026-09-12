import Foundation
import spacesterminalcore

/// What Spaces should offer to bring back, derived from what every known device reports on its daemon
/// status and from the records this client has already answered.
///
/// Pure, and shared by the two surfaces that render it (the launch setup step and the sheet a running
/// app puts up when a device reports a record), so the offer reads the same wherever it appears and
/// neither surface can decide on its own what is outstanding.
///
/// A device keeps its record until some client answers Restore or Skip, so "already answered" is client
/// state (`SessionRestoreAnsweredGenerations`), not something the device can report. Answering is what
/// clears the record; the generation is what makes the answer specific to the record the user saw.
struct SessionRestoreOffer: Equatable {
    /// One captured coding-agent session, as the list shows it.
    struct Row: Equatable {
        let sessionID: String
        let workspaceID: String
        /// The coding agent the daemon classified the session as, or nil when detection never named one.
        let agentLabel: String?
        let title: String
        let workingDirectory: String
        /// The agent reported no conversation id, so restoring relaunches its original command as a new
        /// conversation. The list says this out loud: it is the one way a restored session differs from
        /// the one it replaces.
        let startsNewConversation: Bool

        /// How the row is worded wherever it is named: in the list, and in the report of what could not be
        /// restored. Shared so the dialog line reads like the list entry the user just answered.
        ///
        /// A session Spaces started for an agent is titled after that agent, so naming both would read
        /// "opencode: opencode". The agent's name alone is the whole of what such a row has to say.
        var displayLabel: String {
            guard let agentLabel, agentLabel.caseInsensitiveCompare(title) != .orderedSame else { return title }
            return "\(agentLabel): \(title)"
        }
    }

    /// The rows of one workspace, under the heading the list groups them beneath.
    struct WorkspaceGroup: Equatable {
        /// What the list puts above the group: the workspace's name when this client knows it, and the
        /// working directory of the group's first row when it does not. The launch step runs before any
        /// overview is loaded, so at that moment the device's workspace catalog does not exist yet on
        /// this client, while the reconnect sheet always has it.
        let heading: String
        let rows: [Row]
    }

    /// One device's outstanding record.
    struct DeviceOffer: Equatable {
        let deviceID: String
        let deviceName: String
        /// The capture Restore and Skip carry back. Every row of a record shares it, so a click on an
        /// offer the device has already replaced cannot act on the newer record.
        let generation: String
        let groups: [WorkspaceGroup]

        var rows: [Row] { groups.flatMap(\.rows) }
    }

    /// One device's contribution to the decision.
    struct DeviceInput {
        let deviceID: String
        let deviceName: String
        /// What the device last reported, or nil when it has not reported at all (offline, or not yet
        /// handshaken). A device that says nothing offers nothing.
        let status: TerminalServiceDaemonStatus?
        /// Workspace names this client can put on a group heading, empty when it has no catalog yet.
        let workspaceNamesByID: [String: String]
        /// The generation of this device's record this client already answered, if any.
        let answeredGeneration: String?

        init(
            deviceID: String, deviceName: String, status: TerminalServiceDaemonStatus?, workspaceNamesByID: [String: String] = [:],
            answeredGeneration: String?
        ) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.status = status
            self.workspaceNamesByID = workspaceNamesByID
            self.answeredGeneration = answeredGeneration
        }
    }

    let devices: [DeviceOffer]

    /// Whether the list names each device. Only worth the extra heading when more than one device is
    /// offering something; the common case is This Mac alone.
    var namesDevices: Bool { devices.count > 1 }

    var rowCount: Int { devices.reduce(0) { $0 + $1.rows.count } }

    /// The offer to put on screen, or nil when nothing is outstanding (the steady state), and the reason
    /// this returns an optional rather than an empty offer: every caller's first question is whether to
    /// show a surface at all.
    static func make(devices: [DeviceInput]) -> SessionRestoreOffer? {
        let offers = devices.compactMap(deviceOffer(for:))
        return offers.isEmpty ? nil : SessionRestoreOffer(devices: offers)
    }

    private static func deviceOffer(for input: DeviceInput) -> DeviceOffer? {
        // The record reaches this client through the frozen core of the daemon status, which a daemon of
        // any wire version answers, so it is readable across a release skew that the answer is not: an
        // older daemon would relaunch the agents and clear its record while this client failed to read
        // what came back. Offer nothing until the versions match. Nothing is lost by waiting: the device
        // keeps its record, and the status refresh that reports the updated daemon re-runs this decision.
        guard let status = input.status, SpacesWireCompatibility.evaluate(daemonStatus: status).isCompatible else { return nil }
        // The daemon replaces its record wholesale, so every row it reports belongs to one capture and
        // the first row names the generation the answer carries.
        guard let generation = status.restorableSessions.first?.generation, generation != input.answeredGeneration else { return nil }
        return DeviceOffer(
            deviceID: input.deviceID, deviceName: input.deviceName, generation: generation,
            groups: groups(summaries: status.restorableSessions, workspaceNamesByID: input.workspaceNamesByID))
    }

    /// Groups a device's rows by workspace, keeping the order the device reported them in, both for the
    /// groups themselves and within each group, so the list is stable across refreshes.
    private static func groups(summaries: [RestorableSessionSummary], workspaceNamesByID: [String: String]) -> [WorkspaceGroup] {
        var orderedWorkspaceIDs: [String] = []
        var rowsByWorkspaceID: [String: [Row]] = [:]
        for summary in summaries {
            if rowsByWorkspaceID[summary.workspaceID] == nil { orderedWorkspaceIDs.append(summary.workspaceID) }
            rowsByWorkspaceID[summary.workspaceID, default: []].append(
                Row(
                    sessionID: summary.sessionID, workspaceID: summary.workspaceID, agentLabel: summary.agentKind?.displayLabel, title: summary.title,
                    workingDirectory: summary.workingDirectory, startsNewConversation: !summary.hasResumeKey))
        }
        return orderedWorkspaceIDs.compactMap { workspaceID in
            guard let rows = rowsByWorkspaceID[workspaceID], let first = rows.first else { return nil }
            return WorkspaceGroup(heading: workspaceNamesByID[workspaceID] ?? first.workingDirectory, rows: rows)
        }
    }
}
