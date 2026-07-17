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

        var label: String {
            switch self {
            case .waitingForInput: "Waiting for input"
            case .finished: "Finished"
            case .exited: "Exited"
            case .failed: "Failed"
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

/// Pure derivation of attention events from an overview payload. All recency comes from the
/// payload's ISO-8601 fields (`updatedAt`, `exitedAt`); sources without a usable timestamp are
/// skipped rather than dated with a synthesized time.
enum SpacesMobileAttention {
    static func events(in overview: SpacesDeviceOverviewPayload) -> [SpacesMobileAttentionEvent] {
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

        return events
    }

    static func groups(in overview: SpacesDeviceOverviewPayload, dismissedEventIDs: Set<String>) -> [SpacesMobileAttentionGroup] {
        let remaining = events(in: overview).filter { !dismissedEventIDs.contains($0.id) }
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
