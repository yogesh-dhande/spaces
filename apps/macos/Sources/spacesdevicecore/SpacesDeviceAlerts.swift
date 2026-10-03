import Foundation
import spacesterminalcore

/// The one derivation of alert candidates from a device overview, shared by the daemon (to decide which
/// dismissals and flags are still meaningful) and every client (to render alerts).
///
/// Timestamps come from the payload's ISO-8601 fields, parsed with the fractional-second tolerance a
/// Linux daemon's runtime state needs. A source without a usable timestamp is skipped rather than dated
/// with a synthesized time.
extension SpacesDeviceOverviewPayload {
    /// Every alert candidate this overview describes. Hidden workspaces are included; a consumer that
    /// shows only visible workspaces filters with `isWorkspaceVisible`, so a dismissal made while a
    /// workspace is hidden is still recognized when it is shown again.
    public func alertCandidates() -> [SpacesDeviceAlertCandidate] {
        var candidates: [SpacesDeviceAlertCandidate] = []
        var representedSessionIDs: Set<String> = []
        let sessionByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workspaceIDs = Set(workspaces.map(\.id))

        for workspace in workspaces {
            for agent in workspace.codingAgentRows {
                if let sessionID = agent.sessionID { representedSessionIDs.insert(sessionID) }
                let kind: SpacesDeviceAlertKind
                switch agent.activityState {
                case .waiting: kind = .agentWaiting
                case .done: kind = .agentDone
                case .idle, .spinning, .exited: continue
                }
                guard let updatedAt = agent.updatedAt, let date = Self.alertDate(updatedAt) else { continue }
                candidates.append(
                    SpacesDeviceAlertCandidate(
                        key: "agent:\(agent.id):\(agent.activityState.rawValue):\(updatedAt)", kind: kind, workspaceID: workspace.id,
                        sessionID: agent.sessionID, subjectID: agent.id, date: date))
            }

            for process in workspace.processRows {
                if let sessionID = process.sessionID { representedSessionIDs.insert(sessionID) }
                guard process.runState == .exited, let exitedAt = process.exitedAt, let date = Self.alertDate(exitedAt) else { continue }
                candidates.append(
                    SpacesDeviceAlertCandidate(
                        key: "process:\(process.id):\(exitedAt)", kind: .processExited, workspaceID: workspace.id, sessionID: process.sessionID,
                        subjectID: process.id, date: date))
            }

            for terminal in workspace.terminalRows {
                if let sessionID = terminal.sessionID { representedSessionIDs.insert(sessionID) }
                guard terminal.runState == .exited, let sessionID = terminal.sessionID, let session = sessionByID[sessionID],
                    let kind = Self.terminalAlertKind(for: session.state), let date = Self.alertDate(session.updatedAt)
                else { continue }
                candidates.append(
                    SpacesDeviceAlertCandidate(
                        key: "terminal:\(terminal.id):\(session.state.rawValue):\(session.updatedAt)", kind: kind, workspaceID: workspace.id,
                        sessionID: sessionID, subjectID: terminal.id, date: date))
            }
        }

        // A session already shown by a workspace row is that row's alert (or non-alert), never a second one.
        for session in sessions
        where session.rowKind == .liveSession && !representedSessionIDs.contains(session.id) && workspaceIDs.contains(session.workspaceID) {
            guard let kind = Self.terminalAlertKind(for: session.state), let date = Self.alertDate(session.updatedAt) else { continue }
            candidates.append(
                SpacesDeviceAlertCandidate(
                    key: "session:\(session.id):\(session.state.rawValue):\(session.updatedAt)", kind: kind, workspaceID: session.workspaceID,
                    sessionID: session.id, subjectID: session.id, date: date))
        }

        // A bell is a fact about the session, so it is a candidate whether or not a row shows the session.
        // Whether the user is looking at the session is the client's call; the daemon cannot see focus.
        for session in sessions where workspaceIDs.contains(session.workspaceID) {
            guard let bellAt = session.bellAt, let date = Self.alertDate(bellAt) else { continue }
            candidates.append(
                SpacesDeviceAlertCandidate(
                    key: "bell:\(session.id):\(bellAt)", kind: .bell, workspaceID: session.workspaceID, sessionID: session.id,
                    subjectID: session.id, date: date))
        }

        for run in automationRuns {
            let kind: SpacesDeviceAlertKind
            switch AutomationRunStatus(rawValue: run.status) {
            case .failed: kind = .automationRunFailed
            case .timedOut: kind = .automationRunTimedOut
            default: continue
            }
            guard let date = Self.alertDate(run.endedAt ?? run.createdAt) else { continue }
            candidates.append(
                SpacesDeviceAlertCandidate(
                    key: "automationrun:\(run.id):\(run.status)", kind: kind, workspaceID: nil, sessionID: run.terminalSessionID, subjectID: run.id,
                    date: date))
        }

        for flag in comeBackLaterFlags {
            guard let row = Self.comeBackLaterRow(for: flag, in: workspaces) else { continue }
            candidates.append(
                SpacesDeviceAlertCandidate(
                    key: flag.alertKey, kind: .comeBackLater, workspaceID: row.workspaceID, sessionID: row.sessionID, subjectID: flag.rowID,
                    date: Self.alertDate(flag.flaggedAt)))
        }
        return candidates
    }

    /// This overview with `comeBackLaterFlags` and `dismissedAlertKeys` narrowed to what is still
    /// meaningful: flags whose row exists, dismissals whose alert is still a candidate. The daemon
    /// publishes this view; the stored rows it came from are pruned only by the alert mutations (see
    /// `docs/implementation.md`).
    public func reconcilingAlertState() -> SpacesDeviceOverviewPayload {
        let candidates = alertCandidates()
        let candidateKeys = Set(candidates.map(\.key))
        return SpacesDeviceOverviewPayload(
            projects: projects, workspaces: workspaces, sessions: sessions, retainedTerminalSessionIDs: retainedTerminalSessionIDs,
            workspaceIDsWithTeardownInFlight: workspaceIDsWithTeardownInFlight, daemonStatus: daemonStatus, automations: automations,
            automationRuns: automationRuns, dismissedAlertKeys: dismissedAlertKeys.filter(candidateKeys.contains),
            comeBackLaterFlags: comeBackLaterFlags.filter { candidateKeys.contains($0.alertKey) })
    }

    /// The workspace row a flag sits on, or nil when the overview no longer lists it.
    public static func comeBackLaterRow(for flag: SpacesDeviceComeBackLaterFlag, in workspaces: [SpacesDeviceWorkspaceSummary]) -> (
        workspaceID: String, sessionID: String?
    )? {
        for workspace in workspaces {
            switch flag.rowKind {
            case .agent:
                if let row = workspace.codingAgentRows.first(where: { $0.id == flag.rowID }) { return (workspace.id, row.sessionID) }
            case .process:
                if let row = workspace.processRows.first(where: { $0.id == flag.rowID }) { return (workspace.id, row.sessionID) }
            case .terminal:
                if let row = workspace.terminalRows.first(where: { $0.id == flag.rowID }) { return (workspace.id, row.sessionID) }
            }
        }
        return nil
    }

    private static func alertDate(_ value: String) -> Date? {
        value.isEmpty ? nil : GhosttyRemoteSessionStateTimestamp.date(from: value)
    }

    private static func terminalAlertKind(for state: TerminalSessionState) -> SpacesDeviceAlertKind? {
        switch state {
        case .exited: .terminalExited
        case .failed: .terminalFailed
        case .starting, .running: nil
        }
    }
}
