import Foundation
import spacesdevicecore
import spacesterminalcore

/// One attention-worthy state change derived from the overview payload: an agent waiting for
/// input, an agent that finished, or an exited/failed process or terminal.
struct SpacesMobileAttentionEvent: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case waitingForInput
        case finished
        case exited
        case failed
        case bell
    }

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

    /// Stable dismissal identity within this event's own device: the same source in the same state at
    /// the same time stays dismissed across refreshes; a new state change mints a new identity. This is
    /// exactly what `SpacesMobileDismissedAlertsStore` persists in a device's own bucket, unprefixed: the
    /// same string this type has always used, so a dismissal made before events carried a device id still
    /// suppresses its event.
    var eventKey: String { "\(sourceID)|\(kind.rawValue)|\(date.timeIntervalSinceReferenceDate)" }

    /// `Identifiable` conformance for SwiftUI (`ForEach`, the dismiss button's accessibility id, the
    /// terminal navigation route): qualified by device, unlike `eventKey`, because the Alerts tab lists
    /// every paired device's events in one flat list and two devices' events could otherwise share an
    /// `eventKey` shape.
    var id: String { "\(deviceID)|\(eventKey)" }

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

/// Pure derivation of attention events from an overview payload. All recency comes from the
/// payload's ISO-8601 fields (`updatedAt`, `exitedAt`); sources without a usable timestamp are
/// skipped rather than dated with a synthesized time.
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
    ///   - focusedSessionID: the session the user is watching right now, whose bell is happening in front
    ///     of them rather than being something to alert about.
    ///   - watchWindowsBySessionID: the user's recent watches of each recently watched session. A bell for
    ///     the focused session is excluded live by `focusedSessionID` above; once that session stops being
    ///     focused, these remembered windows keep excluding a bell that rang while it still was, since a
    ///     bell inside any of them is one the user already saw ring in the terminal itself.
    ///   - includingHiddenWorkspaces: when true, a workspace's events are derived even while it (or its
    ///     project) is hidden, instead of being skipped. Defaults to false so the Alerts tab and its badge
    ///     stay unaffected; the only caller that opts in is `retainedDismissedEventIDs`, which needs a
    ///     hidden workspace's events to still be derivable so their dismissals survive hiding (see that
    ///     function's doc comment).
    static func events(
        deviceID: String, deviceText: String?, in overview: SpacesDeviceOverviewPayload, focusedSessionID: String?,
        watchWindowsBySessionID: [String: [SpacesMobileTerminalWatchWindow]], includingHiddenWorkspaces: Bool = false, isDeviceOffline: Bool = false
    ) -> [SpacesMobileAttentionEvent] {
        var events: [SpacesMobileAttentionEvent] = []
        var representedSessionIDs: Set<String> = []
        let sessionByID = Dictionary(uniqueKeysWithValues: overview.sessions.map { ($0.id, $0) })
        // Every event is grouped under its workspace, so a session only produces one when this overview
        // still describes a workspace to attribute it to: a workspace hidden by its own flag or by its
        // project's (see `SpacesDeviceOverviewPayload.isWorkspaceVisible`) has its sessions suppressed
        // with it (unless `includingHiddenWorkspaces`), and a session whose workspace record is gone
        // entirely — a deleted workspace's sessions linger for a refresh or two after its record — has no
        // workspace to attribute it to at all.
        let bandedWorkspaceIDs = Set(overview.workspaces.lazy.filter { includingHiddenWorkspaces || overview.isWorkspaceVisible($0) }.map(\.id))
        let workspaceByID = Dictionary(uniqueKeysWithValues: overview.workspaces.map { ($0.id, $0) })

        func makeEvent(
            sourceID: String, kind: SpacesMobileAttentionEvent.Kind, date: Date, title: String, rowType: SpacesMobileWorkspaceRowType,
            sessionID: String?, workspaceID: String
        ) -> SpacesMobileAttentionEvent {
            let workspace = workspaceByID[workspaceID]
            let sampleSession = sessionID.flatMap { sessionByID[$0] }
            return SpacesMobileAttentionEvent(
                sourceID: sourceID, kind: kind, date: date, title: title, rowType: rowType, sessionID: sessionID, workspaceID: workspaceID,
                deviceID: deviceID, projectName: workspace?.projectName ?? sampleSession?.projectName ?? "Unassigned",
                workspaceDisplayName: workspace?.displayName ?? sampleSession?.workspaceTitle ?? "Unassigned", deviceText: deviceText,
                isDeviceOffline: isDeviceOffline)
        }

        for workspace in overview.workspaces where includingHiddenWorkspaces || overview.isWorkspaceVisible(workspace) {
            for agent in workspace.codingAgentRows {
                if let sessionID = agent.sessionID { representedSessionIDs.insert(sessionID) }
                let kind: SpacesMobileAttentionEvent.Kind?
                switch agent.activityState {
                case .waiting: kind = .waitingForInput
                case .done: kind = .finished
                // Exited raises no attention event: the agent is gone, nothing needs the user.
                case .idle, .spinning, .exited: kind = nil
                }
                guard let kind, let date = date(fromISO8601: agent.updatedAt) else { continue }
                events.append(
                    makeEvent(
                        sourceID: "agent:\(agent.id)", kind: kind, date: date, title: agent.name, rowType: .codingAgents, sessionID: agent.sessionID,
                        workspaceID: workspace.id))
            }

            for process in workspace.processRows {
                if let sessionID = process.sessionID { representedSessionIDs.insert(sessionID) }
                guard process.runState == .exited, let date = date(fromISO8601: process.exitedAt) else { continue }
                events.append(
                    makeEvent(
                        sourceID: "process:\(process.id)", kind: .exited, date: date, title: process.name, rowType: .processes,
                        sessionID: process.sessionID, workspaceID: workspace.id))
            }

            for terminal in workspace.terminalRows {
                if let sessionID = terminal.sessionID { representedSessionIDs.insert(sessionID) }
                guard terminal.runState == .exited, let sessionID = terminal.sessionID, let session = sessionByID[sessionID] else { continue }
                guard let kind = terminalKind(for: session.state), let date = date(fromISO8601: session.updatedAt) else { continue }
                events.append(
                    makeEvent(
                        sourceID: "terminal:\(terminal.id)", kind: kind, date: date, title: terminal.title, rowType: .workspaceTerminals,
                        sessionID: sessionID, workspaceID: workspace.id))
            }
        }

        // Loose sessions: the same dedupe rule as the home tab's terminal groups — a session already
        // represented by a workspace row is that row's event (or non-event), never a second one.
        for session in overview.sessions
        where session.rowKind == .liveSession && !representedSessionIDs.contains(session.id) && bandedWorkspaceIDs.contains(session.workspaceID) {
            guard let kind = terminalKind(for: session.state), let date = date(fromISO8601: session.updatedAt) else { continue }
            events.append(
                makeEvent(
                    sourceID: "session:\(session.id)", kind: kind, date: date, title: session.title, rowType: .workspaceTerminals,
                    sessionID: session.id, workspaceID: session.workspaceID))
        }

        // A bell is a fact about the session itself, not the row-level exit/agent state the dedupe above
        // guards against, so every session with a bell gets an event regardless of representedSessionIDs.
        // The daemon records a bell no matter which client (if any) is looking at the session, since it
        // can't see client focus: a Ghostty attachment survives tab switches, and iOS backgrounding just
        // drops the socket without detaching. Each client is responsible for dropping the alert for the
        // session it currently has open.
        for session in overview.sessions where session.id != focusedSessionID && bandedWorkspaceIDs.contains(session.workspaceID) {
            guard let date = date(fromISO8601: session.bellAt) else { continue }
            // Any window, not just the newest: one visit to a terminal is split into several by the app
            // backgrounding and returning, and the bell may belong to any of them.
            if watchWindowsBySessionID[session.id]?.contains(where: { $0.contains(date, tolerance: watchedBellSkewTolerance) }) == true { continue }
            events.append(
                makeEvent(
                    sourceID: "session:\(session.id)", kind: .bell, date: date, title: session.title, rowType: .workspaceTerminals,
                    sessionID: session.id, workspaceID: session.workspaceID))
        }

        return events
    }

    /// The permissive event derivation every caller that needs a source's *true* event identity — not the
    /// Alerts tab's filtered view of it — shares: no focused session, no watch windows, hidden workspaces
    /// included. A row's exited-process dot and its "Dismiss Alert" menu item both key off this, so
    /// neither depends on what the Alerts tab happens to be suppressing right now (a watched bell, a
    /// hidden workspace) — only on whether the source is still in the state that produced the event.
    static func allEvents(deviceID: String, in overview: SpacesDeviceOverviewPayload) -> [SpacesMobileAttentionEvent] {
        events(
            deviceID: deviceID, deviceText: nil, in: overview, focusedSessionID: nil, watchWindowsBySessionID: [:], includingHiddenWorkspaces: true)
    }

    /// The dismissals worth keeping in one device's bucket: a dismissal only means anything while its
    /// event is still derivable, so the stored set is trimmed to the `eventKey`s `overview` still
    /// produces. Without this, dismissals accumulate forever across launches.
    ///
    /// Derivation here deliberately suppresses nothing — no focused session, no watch windows, and hidden
    /// workspaces included — because a temporarily suppressed event is still one this overview describes,
    /// and pruning its dismissal would make it alert again once the suppression lapsed. Hiding a workspace,
    /// directly or via its project, is exactly such a suppression: both are reversible from iOS (the
    /// Workspaces sheet's checkboxes), and reversing either must not resurface alerts the user
    /// already dismissed while it was hidden. A workspace the overview has stopped describing altogether
    /// is not suppressed but deleted, so its dismissals do prune — there is nothing left to resurface them.
    static func retainedDismissedEventIDs(_ dismissed: Set<String>, deviceID: String, in overview: SpacesDeviceOverviewPayload) -> Set<String> {
        dismissed.intersection(Set(allEvents(deviceID: deviceID, in: overview).map(\.eventKey)))
    }

    /// Parses the daemon's ISO-8601 timestamps, including the fractional seconds emitted by Linux
    /// runtime state. Unparseable or absent values return nil so the caller skips the source.
    static func date(fromISO8601 value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return GhosttyRemoteSessionStateTimestamp.date(from: value)
    }

    private static func terminalKind(for state: TerminalSessionState) -> SpacesMobileAttentionEvent.Kind? {
        switch state {
        case .exited: .exited
        case .failed: .failed
        case .starting, .running: nil
        }
    }
}

extension SpacesMobileWorkspaceRuntimeRow {
    /// Whether `event` is this row's own attention event. A process/agent/terminal-kind event and its row
    /// are built from the same underlying record, so their ids share the same `"kind:recordID"` string —
    /// matching on `id` alone lines them up. A bell is different: it is a fact about the session, keyed by
    /// session id (`"session:…"`), which never equals a terminal row's own id (`"terminal:…"`), so it
    /// matches by `sessionID` instead.
    func matches(_ event: SpacesMobileAttentionEvent) -> Bool {
        guard event.workspaceID == workspaceID else { return false }
        if event.sourceID == id { return true }
        return event.kind == .bell && sessionID != nil && event.sessionID == sessionID
    }
}
