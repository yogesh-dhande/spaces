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

        var label: String {
            switch self {
            case .waitingForInput: "Waiting for input"
            case .finished: "Finished"
            case .exited: "Exited"
            case .failed: "Failed"
            case .bell: "Bell"
            }
        }
    }

    let sourceID: String
    let kind: Kind
    let date: Date
    let title: String
    let rowType: SpacesMobileWorkspaceRowType
    let sessionID: String?
    let workspaceID: String

    /// Stable dismissal identity: the same source in the same state at the same time stays
    /// dismissed across refreshes; a new state change mints a new identity.
    var id: String { "\(sourceID)|\(kind.rawValue)|\(date.timeIntervalSinceReferenceDate)" }
}

/// Attention events for one workspace, newest first.
struct SpacesMobileAttentionGroup: Identifiable, Equatable, Sendable {
    let workspaceID: String
    let workspaceDisplayName: String
    let projectName: String
    let isGitWorkspace: Bool
    let events: [SpacesMobileAttentionEvent]

    var id: String { workspaceID }
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
    ///   - focusedSessionID: the session the user is watching right now, whose bell is happening in front
    ///     of them rather than being something to alert about.
    ///   - watchWindowsBySessionID: the user's recent watches of each recently watched session. Overview
    ///     polling is paused while a detail is open, so a bell rung during a watch is first seen after
    ///     that watch ended — a bell inside any of them is one the user saw ring.
    static func events(
        in overview: SpacesDeviceOverviewPayload, focusedSessionID: String?, watchWindowsBySessionID: [String: [SpacesMobileTerminalWatchWindow]]
    ) -> [SpacesMobileAttentionEvent] {
        var events: [SpacesMobileAttentionEvent] = []
        var representedSessionIDs: Set<String> = []
        let sessionByID = Dictionary(uniqueKeysWithValues: overview.sessions.map { ($0.id, $0) })
        let invisibleWorkspaceIDs = Set(overview.workspaces.lazy.filter { $0.isArchived || $0.isHidden }.map(\.id))

        for workspace in overview.workspaces where !workspace.isArchived && !workspace.isHidden {
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
                    SpacesMobileAttentionEvent(
                        sourceID: "agent:\(agent.id)", kind: kind, date: date, title: agent.name, rowType: .codingAgents, sessionID: agent.sessionID,
                        workspaceID: workspace.id))
            }

            for process in workspace.processRows {
                if let sessionID = process.sessionID { representedSessionIDs.insert(sessionID) }
                guard process.runState == .exited, let date = date(fromISO8601: process.exitedAt) else { continue }
                events.append(
                    SpacesMobileAttentionEvent(
                        sourceID: "process:\(process.id)", kind: .exited, date: date, title: process.name, rowType: .processes,
                        sessionID: process.sessionID, workspaceID: workspace.id))
            }

            for terminal in workspace.terminalRows {
                if let sessionID = terminal.sessionID { representedSessionIDs.insert(sessionID) }
                guard terminal.runState == .exited, let sessionID = terminal.sessionID, let session = sessionByID[sessionID] else { continue }
                guard let kind = terminalKind(for: session.state), let date = date(fromISO8601: session.updatedAt) else { continue }
                events.append(
                    SpacesMobileAttentionEvent(
                        sourceID: "terminal:\(terminal.id)", kind: kind, date: date, title: terminal.title, rowType: .workspaceTerminals,
                        sessionID: sessionID, workspaceID: workspace.id))
            }
        }

        // Loose sessions: the same dedupe rule as the home tab's terminal groups — a session already
        // represented by a workspace row is that row's event (or non-event), never a second one.
        for session in overview.sessions
        where session.rowKind == .liveSession && !representedSessionIDs.contains(session.id) && !invisibleWorkspaceIDs.contains(session.workspaceID) {
            guard let kind = terminalKind(for: session.state), let date = date(fromISO8601: session.updatedAt) else { continue }
            events.append(
                SpacesMobileAttentionEvent(
                    sourceID: "session:\(session.id)", kind: kind, date: date, title: session.title, rowType: .workspaceTerminals,
                    sessionID: session.id, workspaceID: session.workspaceID))
        }

        // A bell is a fact about the session itself, not the row-level exit/agent state the dedupe above
        // guards against, so every session with a bell gets an event regardless of representedSessionIDs.
        // The daemon records a bell no matter which client (if any) is looking at the session, since it
        // can't see client focus: a Ghostty attachment survives tab switches, and iOS backgrounding just
        // drops the socket without detaching. Each client is responsible for dropping the alert for the
        // session it currently has open.
        for session in overview.sessions where session.id != focusedSessionID && !invisibleWorkspaceIDs.contains(session.workspaceID) {
            guard let date = date(fromISO8601: session.bellAt) else { continue }
            // Any window, not just the newest: one visit to a terminal is split into several by the app
            // backgrounding and returning, and the bell may belong to any of them.
            if watchWindowsBySessionID[session.id]?.contains(where: { $0.contains(date, tolerance: watchedBellSkewTolerance) }) == true { continue }
            events.append(
                SpacesMobileAttentionEvent(
                    sourceID: "session:\(session.id)", kind: .bell, date: date, title: session.title, rowType: .workspaceTerminals,
                    sessionID: session.id, workspaceID: session.workspaceID))
        }

        return events
    }

    static func groups(
        in overview: SpacesDeviceOverviewPayload, dismissedEventIDs: Set<String>, focusedSessionID: String?,
        watchWindowsBySessionID: [String: [SpacesMobileTerminalWatchWindow]]
    ) -> [SpacesMobileAttentionGroup] {
        let remaining = events(in: overview, focusedSessionID: focusedSessionID, watchWindowsBySessionID: watchWindowsBySessionID).filter {
            !dismissedEventIDs.contains($0.id)
        }
        guard !remaining.isEmpty else { return [] }
        let workspaceByID = Dictionary(uniqueKeysWithValues: overview.workspaces.map { ($0.id, $0) })
        let sessionByID = Dictionary(uniqueKeysWithValues: overview.sessions.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: remaining) { $0.workspaceID }

        return grouped.map { workspaceID, events in
            let workspace = workspaceByID[workspaceID]
            let sampleSession = events.compactMap { $0.sessionID.flatMap { sessionByID[$0] } }.first
            return SpacesMobileAttentionGroup(
                workspaceID: workspaceID, workspaceDisplayName: workspace?.displayName ?? sampleSession?.workspaceTitle ?? "Unassigned",
                projectName: workspace?.projectName ?? sampleSession?.projectName ?? "Unassigned", isGitWorkspace: workspace?.isGitWorkspace ?? false,
                events: events.sorted { $0.date > $1.date })
        }.sorted { lhs, rhs in
            guard let lhsNewest = lhs.events.first?.date, let rhsNewest = rhs.events.first?.date else { return false }
            if lhsNewest != rhsNewest { return lhsNewest > rhsNewest }
            return lhs.workspaceID < rhs.workspaceID
        }
    }

    /// Parses the daemon's ISO-8601 timestamps, including the fractional seconds emitted by Linux
    /// runtime state. Unparseable or absent values return nil so the caller skips the source.
    static func date(fromISO8601 value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return GhosttyRemoteSessionStateTimestamp.date(from: value)
    }

    /// Abbreviated relative age for event rows: "now", "5m", "3h", "2d".
    static func abbreviatedAge(of date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "now" }
        let minutes = Int(seconds / 60)
        guard minutes >= 60 else { return "\(minutes)m" }
        let hours = minutes / 60
        guard hours >= 24 else { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private static func terminalKind(for state: TerminalSessionState) -> SpacesMobileAttentionEvent.Kind? {
        switch state {
        case .exited: .exited
        case .failed: .failed
        case .starting, .running: nil
        }
    }
}
