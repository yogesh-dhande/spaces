import Foundation
import spacesdevicecore
import spacesterminalcore

/// One attention-worthy state change derived from the overview payload: an agent waiting for
/// input, an agent that finished, an exited/failed process or terminal, a bell, or a row marked Come Back
/// Later.
struct SpacesMobileAttentionEvent: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case waitingForInput
        case finished
        case exited
        case failed
        case bell
        case comeBackLater
    }

    /// The device's own alert key (`SpacesDeviceAlertCandidate.key`): the identity its dismissal is
    /// recorded under, shared by every client of that device.
    let key: String
    /// The row-family id (`agent:`, `process:`, `terminal:`) or `session:` id of the thing this event is
    /// about; see `SpacesMobileWorkspaceRuntimeRow.matches`.
    let sourceID: String
    let kind: Kind
    let date: Date
    let title: String
    let rowType: SpacesMobileWorkspaceRowType
    let sessionID: String?
    let workspaceID: String
    let deviceID: String
    let projectName: String
    let workspaceDisplayName: String
    /// "Device Name" / "Device Name (offline)", or nil when the device segment is hidden; see
    /// `SpacesMobileDeviceDisplay.showsDeviceSegment`.
    let deviceText: String?
    /// Whether this event's device is currently offline. The Alerts tab dims the row on this rather than
    /// re-deriving it from `deviceText`, which is nil whenever the device segment itself is hidden.
    let isDeviceOffline: Bool

    /// `Identifiable` conformance for SwiftUI (`ForEach`, the dismiss button's accessibility id, the
    /// terminal navigation route): qualified by device, unlike `key`, because the Alerts tab lists every
    /// paired device's events in one flat list.
    var id: String { "\(deviceID)|\(key)" }

    /// "project / workspace" or "project / workspace · device": the row's detail line. The status dot
    /// already carries the event's kind, so this line carries identity instead of a status label.
    var detail: String {
        let projectWorkspace = SpacesMobileDeviceDisplay.projectWorkspace(projectName: projectName, workspaceDisplayName: workspaceDisplayName)
        guard let deviceText else { return projectWorkspace }
        return "\(projectWorkspace) · \(deviceText)"
    }
}

/// One stretch of time the user spent looking at a session's terminal detail: the route was open and the
/// app was in the foreground for all of it.
///
/// A stretch rather than a single "watch ended" moment because backgrounding the app with a detail open
/// interrupts watching without closing the route. Recording only the end would make everything before it
/// count as watched, and the bells rung while the app was away — exactly the ones the user cannot
/// possibly have seen — would be swallowed on the next refresh. One visit therefore produces a sequence
/// of these, and the stretches between them (the app in the background) are what the user missed.
struct SpacesMobileTerminalWatchWindow: Equatable, Sendable {
    let startedAt: Date
    let endedAt: Date

    /// Whether `date` falls in this watch, widened at both ends by `tolerance` (see
    /// `SpacesMobileAttention.watchedBellSkewTolerance`).
    func contains(_ date: Date, tolerance: TimeInterval) -> Bool {
        date >= startedAt.addingTimeInterval(-tolerance) && date <= endedAt.addingTimeInterval(tolerance)
    }
}

/// Pure derivation of attention events from an overview payload, on top of the shared alert candidates
/// (`SpacesDeviceOverviewPayload.alertCandidates()`). The device decides what is dismissed and which flags
/// exist; this decides only what the user can see on this phone.
enum SpacesMobileAttention {
    /// Slack added to both ends of a watch window when deciding whether a bell rang inside it. `bellAt`
    /// comes from the daemon's clock while the window comes from this phone's, so an exact comparison
    /// would let ordinary skew between two NTP-synced clocks put a watched bell outside the window and
    /// alert for the session the user was just looking at. The cost is bounded the other way: a real bell
    /// rung within the tolerance of the window's edges is dropped, and the daemon's 30-second
    /// bell-coalescing window means the next one alerts normally.
    static let watchedBellSkewTolerance: TimeInterval = 2

    /// - Parameters:
    ///   - deviceID/deviceText: stamped onto every event this call produces; see
    ///     `SpacesMobileAttentionEvent.deviceText`. `deviceText` is nil to hide the device segment.
    ///   - focusedSessionID: the session the user is watching right now. Its bell is hidden whatever its
    ///     time, so a bell never flashes in the list for the terminal on screen before the watched-bell
    ///     dismissal (see `watchedBellKeys`) reaches the device and comes back.
    ///   - watchWindowsBySessionID: hides a bell rung inside a remembered watch the same way, for the gap
    ///     between the watch ending and that dismissal returning.
    ///   - includingHiddenWorkspaces: when true, a hidden workspace's events are derived too. Row-level
    ///     "Dismiss Alert" needs this: hiding a workspace is a display suppression, not a reason a row
    ///     cannot clear its own alerts.
    static func events(
        deviceID: String, deviceText: String?, in overview: SpacesDeviceOverviewPayload, focusedSessionID: String?,
        watchWindowsBySessionID: [String: [SpacesMobileTerminalWatchWindow]], includingHiddenWorkspaces: Bool = false, isDeviceOffline: Bool = false
    ) -> [SpacesMobileAttentionEvent] {
        let dismissed = Set(overview.dismissedAlertKeys)
        let sessionByID = Dictionary(overview.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workspaceByID = Dictionary(overview.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [SpacesMobileAttentionEvent] = []

        for candidate in overview.alertCandidates() {
            guard !dismissed.contains(candidate.key), let date = candidate.date, let workspaceID = candidate.workspaceID,
                let workspace = workspaceByID[workspaceID], includingHiddenWorkspaces || overview.isWorkspaceVisible(workspace),
                let presentation = presentation(of: candidate, in: workspace, sessionByID: sessionByID)
            else { continue }
            if candidate.kind == .bell, let sessionID = candidate.sessionID {
                if sessionID == focusedSessionID { continue }
                // Any window, not just the newest: one visit to a terminal is split into several by the app
                // backgrounding and returning, and the bell may belong to any of them.
                if isWatched(bellAt: date, sessionID: sessionID, watchWindowsBySessionID: watchWindowsBySessionID) { continue }
            }
            events.append(
                SpacesMobileAttentionEvent(
                    key: candidate.key, sourceID: presentation.sourceID, kind: presentation.kind, date: date, title: presentation.title,
                    rowType: presentation.rowType, sessionID: candidate.sessionID, workspaceID: workspaceID, deviceID: deviceID,
                    projectName: workspace.projectName, workspaceDisplayName: workspace.displayName, deviceText: deviceText,
                    isDeviceOffline: isDeviceOffline))
        }
        return events
    }

    /// Keys of the undismissed bells that rang while the user was watching their session, which the
    /// caller dismisses on the device so every client drops them. Windows must include the watch still
    /// open, so a bell rung during it counts; a bell rung before the watch began never does, because
    /// focusing a session does not clear an alert from a bell it rang earlier.
    static func watchedBellKeys(in overview: SpacesDeviceOverviewPayload, watchWindowsBySessionID: [String: [SpacesMobileTerminalWatchWindow]])
        -> [String]
    {
        let dismissed = Set(overview.dismissedAlertKeys)
        return overview.alertCandidates().compactMap { candidate in
            guard candidate.kind == .bell, !dismissed.contains(candidate.key), let sessionID = candidate.sessionID, let date = candidate.date,
                isWatched(bellAt: date, sessionID: sessionID, watchWindowsBySessionID: watchWindowsBySessionID)
            else { return nil }
            return candidate.key
        }
    }

    private static func isWatched(bellAt date: Date, sessionID: String, watchWindowsBySessionID: [String: [SpacesMobileTerminalWatchWindow]]) -> Bool {
        watchWindowsBySessionID[sessionID]?.contains(where: { $0.contains(date, tolerance: watchedBellSkewTolerance) }) == true
    }

    private struct Presentation {
        let sourceID: String
        let kind: SpacesMobileAttentionEvent.Kind
        let title: String
        let rowType: SpacesMobileWorkspaceRowType
    }

    /// How a candidate reads in the list, or nil when its row is gone from the workspace (an automation
    /// run, which `SpacesMobileAutomationAlerts` presents, or a row removed since the candidate was derived).
    private static func presentation(
        of candidate: SpacesDeviceAlertCandidate, in workspace: SpacesDeviceWorkspaceSummary, sessionByID: [String: SpacesDeviceTerminalSessionSummary]
    ) -> Presentation? {
        switch candidate.kind {
        case .agentWaiting, .agentDone:
            guard let agent = workspace.codingAgentRows.first(where: { $0.id == candidate.subjectID }) else { return nil }
            return Presentation(
                sourceID: "agent:\(agent.id)", kind: candidate.kind == .agentWaiting ? .waitingForInput : .finished, title: agent.name,
                rowType: .codingAgents)
        case .processExited:
            guard let process = workspace.processRows.first(where: { $0.id == candidate.subjectID }) else { return nil }
            return Presentation(sourceID: "process:\(process.id)", kind: .exited, title: process.name, rowType: .processes)
        case .terminalExited, .terminalFailed:
            let kind: SpacesMobileAttentionEvent.Kind = candidate.kind == .terminalExited ? .exited : .failed
            if let terminal = workspace.terminalRows.first(where: { $0.id == candidate.subjectID }) {
                return Presentation(sourceID: "terminal:\(terminal.id)", kind: kind, title: terminal.title, rowType: .workspaceTerminals)
            }
            // A loose session no row shows.
            guard let session = sessionByID[candidate.subjectID] else { return nil }
            return Presentation(sourceID: "session:\(session.id)", kind: kind, title: session.title, rowType: .workspaceTerminals)
        case .bell:
            guard let session = sessionByID[candidate.subjectID] else { return nil }
            return Presentation(sourceID: "session:\(session.id)", kind: .bell, title: session.title, rowType: .workspaceTerminals)
        case .comeBackLater:
            guard let reference = SpacesDeviceComeBackLaterFlag.rowReference(fromAlertKey: candidate.key) else { return nil }
            switch reference.rowKind {
            case .agent:
                guard let agent = workspace.codingAgentRows.first(where: { $0.id == reference.rowID }) else { return nil }
                return Presentation(sourceID: "agent:\(agent.id)", kind: .comeBackLater, title: agent.name, rowType: .codingAgents)
            case .process:
                guard let process = workspace.processRows.first(where: { $0.id == reference.rowID }) else { return nil }
                return Presentation(sourceID: "process:\(process.id)", kind: .comeBackLater, title: process.name, rowType: .processes)
            case .terminal:
                guard let terminal = workspace.terminalRows.first(where: { $0.id == reference.rowID }) else { return nil }
                return Presentation(sourceID: "terminal:\(terminal.id)", kind: .comeBackLater, title: terminal.title, rowType: .workspaceTerminals)
            }
        case .automationRunFailed, .automationRunTimedOut: return nil
        }
    }

    /// Parses the daemon's ISO-8601 timestamps, including the fractional seconds emitted by Linux
    /// runtime state. Unparseable or absent values return nil so the caller skips the source.
    static func date(fromISO8601 value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return GhosttyRemoteSessionStateTimestamp.date(from: value)
    }
}

extension SpacesMobileWorkspaceRuntimeRow {
    /// Whether `event` is this row's own attention event. A process/agent/terminal-kind event (a Come Back
    /// Later flag included) and its row are built from the same underlying record, so their ids share the
    /// same `"kind:recordID"` string, so matching on `id` alone lines them up. A bell is different: it is a
    /// fact about the session, keyed by session id (`"session:…"`), which never equals a terminal row's own
    /// id (`"terminal:…"`), so it matches by `sessionID` instead.
    func matches(_ event: SpacesMobileAttentionEvent) -> Bool {
        guard event.workspaceID == workspaceID else { return false }
        if event.sourceID == id { return true }
        return event.kind == .bell && sessionID != nil && event.sessionID == sessionID
    }
}
