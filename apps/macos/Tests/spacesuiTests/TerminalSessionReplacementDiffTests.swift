import Foundation
import Testing
import spacesdevicecore

@testable import spacesui

@Suite struct TerminalSessionReplacementDiffTests {
    private func processRow(id: String, workspaceID: String, sessionID: String?, runState: SpacesDeviceRunState = .running)
        -> SpacesDeviceWorkspaceProcessRow
    {
        SpacesDeviceWorkspaceProcessRow(
            id: id, workspaceID: workspaceID, name: id, command: "echo \(id)", processID: "process-\(id)", sessionID: sessionID, runState: runState,
            canRun: true, canStop: true, canRestart: true)
    }

    private func agentRow(id: String, workspaceID: String, sessionID: String?) -> SpacesDeviceWorkspaceCodingAgentRow {
        SpacesDeviceWorkspaceCodingAgentRow(
            id: id, workspaceID: workspaceID, name: id, command: "claude", agentID: "agent-\(id)", sessionID: sessionID, runState: .running,
            activityState: .idle, canStop: true)
    }

    private func terminalRow(id: String, workspaceID: String, sessionID: String?) -> SpacesDeviceWorkspaceTerminalRow {
        SpacesDeviceWorkspaceTerminalRow(
            id: id, workspaceID: workspaceID, title: id, workingDirectory: "/tmp", sessionID: sessionID, runState: .running, canOpenTerminal: true)
    }

    /// A session list entry naming a `createdAt`, which is how the diff orders a replacement against what
    /// it replaced. A session absent from an overview's `sessions` (an exited session drops out) is
    /// simply not built here, matching the daemon's own behavior.
    private func sessionSummary(id: String, createdAt: String) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: "shell", workingDirectory: "/tmp/workspace", shell: "/bin/zsh", command: nil, state: .running, backend: .ghosttyEmbedded,
            lifetimePolicy: .persistent, servicePID: 1234, childPID: 5678, workspaceID: "ws", workspaceTitle: "Workspace", projectID: "project",
            projectName: "Project", createdAt: createdAt, updatedAt: createdAt, isControlAvailable: true, isSubscriptionAvailable: true,
            attachmentSnapshot: .init())
    }

    private func workspace(
        id: String, processRows: [SpacesDeviceWorkspaceProcessRow] = [], codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = [],
        terminalRows: [SpacesDeviceWorkspaceTerminalRow] = []
    ) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: "project", projectName: "project", branch: nil, baseBranch: nil, dir: "/tmp/\(id)", isRunning: true, isHidden: false,
            isDefault: false, sessionCount: 0, processRows: processRows, codingAgentRows: codingAgentRows, terminalRows: terminalRows)
    }

    private func overview(_ workspaces: [SpacesDeviceWorkspaceSummary], sessions: [SpacesDeviceTerminalSessionSummary] = [])
        -> SpacesDeviceOverviewPayload
    {
        SpacesDeviceOverviewPayload(workspaces: workspaces, sessions: sessions)
    }

    /// The case the diff exists for: a configured process whose run exited is started again. Its row keeps
    /// its id and names the replacement session, which is the only signal the client gets, since the
    /// Device API cannot post the replacement's open. The replaced session has already exited, so it has
    /// left the previous overview's `sessions`: this is why an unknown replaced createdAt must not block
    /// the pairing.
    @Test func aProcessRowThatSwapsItsSessionNamesTheSessionItReplaces() {
        let before = overview([workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "ended", runState: .exited)])])
        let after = overview(
            [workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "replacement")])],
            sessions: [sessionSummary(id: "replacement", createdAt: "2026-07-20T00:01:00Z")])

        #expect(
            TerminalSessionReplacementDiff.replacements(previous: before, current: after) == [
                .init(workspaceID: "ws", replacedSessionID: "ended", replacementSessionID: "replacement")
            ])
    }

    /// Coding-agent and ad hoc terminal rows are restarted the same way and read the same way. Both the
    /// replaced and replacement sessions are still live (running, not yet exited) at their respective
    /// overviews, so both createdAt values are known and the replacement is newer.
    @Test func agentAndTerminalRowsSwapTheirSessionsToo() {
        let before = overview(
            [
                workspace(
                    id: "ws", codingAgentRows: [agentRow(id: "agent:1", workspaceID: "ws", sessionID: "agent-ended")],
                    terminalRows: [terminalRow(id: "terminal-window:1", workspaceID: "ws", sessionID: "shell-ended")])
            ],
            sessions: [
                sessionSummary(id: "agent-ended", createdAt: "2026-07-20T00:00:00Z"),
                sessionSummary(id: "shell-ended", createdAt: "2026-07-20T00:00:00Z"),
            ])
        let after = overview(
            [
                workspace(
                    id: "ws", codingAgentRows: [agentRow(id: "agent:1", workspaceID: "ws", sessionID: "agent-new")],
                    terminalRows: [terminalRow(id: "terminal-window:1", workspaceID: "ws", sessionID: "shell-new")])
            ],
            sessions: [
                sessionSummary(id: "agent-new", createdAt: "2026-07-20T00:01:00Z"),
                sessionSummary(id: "shell-new", createdAt: "2026-07-20T00:01:00Z"),
            ])

        #expect(
            TerminalSessionReplacementDiff.replacements(previous: before, current: after) == [
                .init(workspaceID: "ws", replacedSessionID: "agent-ended", replacementSessionID: "agent-new"),
                .init(workspaceID: "ws", replacedSessionID: "shell-ended", replacementSessionID: "shell-new"),
            ])
    }

    /// An unchanged overview must move nothing: the diff runs on every refresh, and a spurious pairing
    /// would repoint a live pane at another session.
    @Test func anUnchangedOverviewYieldsNoReplacements() {
        let payload = overview([workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "live")])])

        #expect(TerminalSessionReplacementDiff.replacements(previous: payload, current: payload).isEmpty)
    }

    /// A row that is gone entirely is a runtime entry that was removed, which closes its pane rather than
    /// moving it: an ended pane never outlives the entry backing its transcript.
    @Test func aRemovedRowYieldsNoReplacementSoItsPaneStillCloses() {
        let before = overview([workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "ended", runState: .exited)])])
        let after = overview([workspace(id: "ws")])

        #expect(TerminalSessionReplacementDiff.replacements(previous: before, current: after).isEmpty)
    }

    /// A target starting for the first time has no predecessor to inherit a pane from.
    @Test func aRowGainingItsFirstSessionYieldsNoReplacement() {
        let before = overview([workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: nil, runState: .notStarted)])])
        let after = overview([workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "first")])])

        #expect(TerminalSessionReplacementDiff.replacements(previous: before, current: after).isEmpty)
    }

    /// Process rows are identified by their `spaces.yaml` template id, so every workspace of a project has
    /// a row called the same thing. Pairing by row id alone would hand one workspace's pane to another
    /// workspace's replacement session.
    @Test func rowsWithTheSameIDInDifferentWorkspacesAreNeverPaired() {
        let before = overview([
            workspace(id: "ws-a", processRows: [processRow(id: "api", workspaceID: "ws-a", sessionID: "a-ended", runState: .exited)]),
            workspace(id: "ws-b", processRows: [processRow(id: "api", workspaceID: "ws-b", sessionID: "b-live")]),
        ])
        let after = overview(
            [
                workspace(id: "ws-a", processRows: [processRow(id: "api", workspaceID: "ws-a", sessionID: "a-new")]),
                workspace(id: "ws-b", processRows: [processRow(id: "api", workspaceID: "ws-b", sessionID: "b-live")]),
            ], sessions: [sessionSummary(id: "a-new", createdAt: "2026-07-20T00:01:00Z")])

        #expect(
            TerminalSessionReplacementDiff.replacements(previous: before, current: after) == [
                .init(workspaceID: "ws-a", replacedSessionID: "a-ended", replacementSessionID: "a-new")
            ])
    }

    /// The first overview of a device has nothing to compare against, so a client that just connected
    /// adopts what it is told rather than treating every pane as replaced.
    @Test func theFirstOverviewOfADeviceYieldsNoReplacements() {
        let after = overview([workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "live")])])

        #expect(TerminalSessionReplacementDiff.replacements(previous: nil, current: after).isEmpty)
    }

    /// The regression this gate exists for: a subscription push applies the live overview naming session
    /// B, then a slower in-flight pull that snapshotted the pre-restart state applies afterwards and names
    /// session A again. Read naively this is indistinguishable from a restart running the other way
    /// (B replaced by A), but A's createdAt is older than B's, so the ordering gate rejects it.
    @Test func aStaleOverviewNamingAnOlderSessionAfterANewerOneYieldsNoReplacement() {
        let before = overview(
            [workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "session-b")])],
            sessions: [
                sessionSummary(id: "session-a", createdAt: "2026-07-20T00:00:00Z"),
                sessionSummary(id: "session-b", createdAt: "2026-07-20T00:01:00Z"),
            ])
        let after = overview(
            [workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "session-a")])],
            sessions: [
                sessionSummary(id: "session-a", createdAt: "2026-07-20T00:00:00Z"),
                sessionSummary(id: "session-b", createdAt: "2026-07-20T00:01:00Z"),
            ])

        #expect(TerminalSessionReplacementDiff.replacements(previous: before, current: after).isEmpty)
    }

    /// The stale-overview counterpart of the exited-start forward case: the stale overview's row still
    /// names the session that had exited by the time it was captured, so that candidate replacement id is
    /// absent from the current overview's `sessions`. Requiring a known replacement rejects this the same
    /// way requiring a known replaced would have missed the exited-start forward case.
    @Test func aCandidateReplacementAbsentFromCurrentSessionsYieldsNoReplacement() {
        let before = overview(
            [workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "session-b")])],
            sessions: [sessionSummary(id: "session-b", createdAt: "2026-07-20T00:01:00Z")])
        let after = overview([workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "session-a")])], sessions: [])

        #expect(TerminalSessionReplacementDiff.replacements(previous: before, current: after).isEmpty)
    }

    /// Strictly newer, not merely not-older, is required: two rows that happen to record the identical
    /// createdAt are not a restart (a restart always creates a new row), so the comparison must reject
    /// equality rather than accept it.
    @Test func equalCreatedAtYieldsNoReplacement() {
        let before = overview(
            [workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "session-a")])],
            sessions: [sessionSummary(id: "session-a", createdAt: "2026-07-20T00:00:00Z")])
        let after = overview(
            [workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "session-b")])],
            sessions: [sessionSummary(id: "session-b", createdAt: "2026-07-20T00:00:00Z")])

        #expect(TerminalSessionReplacementDiff.replacements(previous: before, current: after).isEmpty)
    }

    /// A rapid restart within the same wall-clock second must still pair: `createdAt` is stamped with
    /// sub-second precision precisely so this case is distinguishable from `equalCreatedAtYieldsNoReplacement`.
    @Test func createdAtDifferingOnlyInFractionalSecondsStillPairs() {
        let before = overview(
            [workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "session-a")])],
            sessions: [sessionSummary(id: "session-a", createdAt: "2026-07-20T00:00:00.100Z")])
        let after = overview(
            [workspace(id: "ws", processRows: [processRow(id: "api", workspaceID: "ws", sessionID: "session-b")])],
            sessions: [sessionSummary(id: "session-b", createdAt: "2026-07-20T00:00:00.900Z")])

        #expect(
            TerminalSessionReplacementDiff.replacements(previous: before, current: after) == [
                .init(workspaceID: "ws", replacedSessionID: "session-a", replacementSessionID: "session-b")
            ])
    }
}
