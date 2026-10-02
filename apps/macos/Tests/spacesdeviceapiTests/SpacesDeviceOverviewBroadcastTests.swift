import Foundation
import Testing
import spacesdevicecore
import spacesterminalcore
import spacestestsupport

@testable import spacesdeviceapi

/// Fixtures for the overview-broadcast decision tests below. Every value not being varied by a given test
/// is held constant, so a diff between two fixtures is exactly the field the test means to change.
private func makeSession(
    id: String = "session-1", liveTitle: String? = nil, workingDirectory: String = "/repo", updatedAt: String = "2026-01-01T00:00:00Z",
    bellAt: String? = nil
) -> SpacesDeviceTerminalSessionSummary {
    SpacesDeviceTerminalSessionSummary(
        id: id, title: "shell-1", liveTitle: liveTitle, workingDirectory: workingDirectory, shell: "/bin/zsh", command: nil, state: .running,
        backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 1, childPID: nil, workspaceID: "workspace-1", workspaceTitle: "Feature",
        projectID: "project-1", projectName: "Project", createdAt: "2026-01-01T00:00:00Z", updatedAt: updatedAt, isControlAvailable: true,
        isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), bellAt: bellAt)
}

private func makeCodingAgentRow(
    id: String = "agent:1", liveTitle: String? = nil, runState: SpacesDeviceRunState = .running,
    activityState: SpacesDeviceCodingAgentActivityState = .idle
) -> SpacesDeviceWorkspaceCodingAgentRow {
    SpacesDeviceWorkspaceCodingAgentRow(
        id: id, workspaceID: "workspace-1", name: "Coding Agent", command: "claude", agentID: "agent-1", sessionID: "session-2", runState: runState,
        activityState: activityState, brief: nil, briefUpdatedAt: nil, canStop: true, liveTitle: liveTitle)
}

private func makeTerminalRow(id: String = "terminal-window:1", workingDirectory: String = "/repo", liveTitle: String? = nil)
    -> SpacesDeviceWorkspaceTerminalRow
{
    SpacesDeviceWorkspaceTerminalRow(
        id: id, workspaceID: "workspace-1", title: "shell-1", workingDirectory: workingDirectory, sessionID: "session-3", runState: .running,
        canOpenTerminal: true, canStop: true, liveTitle: liveTitle)
}

private func makeWorkspace(codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = [], terminalRows: [SpacesDeviceWorkspaceTerminalRow] = [])
    -> SpacesDeviceWorkspaceSummary
{
    SpacesDeviceWorkspaceSummary(
        id: "workspace-1", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/repo", isRunning: true,
        isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: true, codingAgentRows: codingAgentRows, terminalRows: terminalRows)
}

private func makePayload(
    sessions: [SpacesDeviceTerminalSessionSummary] = [], codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = [],
    terminalRows: [SpacesDeviceWorkspaceTerminalRow] = []
) -> SpacesDeviceOverviewPayload {
    SpacesDeviceOverviewPayload(workspaces: [makeWorkspace(codingAgentRows: codingAgentRows, terminalRows: terminalRows)], sessions: sessions)
}

private func encoded(_ payload: SpacesDeviceOverviewPayload) throws -> Data { try SpacesDeviceOverviewStreamCodec.encodeLine(payload) }

/// `overviewBroadcastDecision` is the pure gate `evaluateOverviewBroadcast` calls on every 250 ms
/// coalesced tick: byte-identical rebuilds are dropped, a real state change always goes out at once, and a
/// metadata-only change (a live title or working directory moving, nothing else) is coalesced to at most
/// one push per `overviewMetadataCoalesceInterval`. Tested as pure logic, matching
/// `SpacesDeviceAPIServerKeepaliveCadenceTests` above, so the coalescing behavior needs no live timer,
/// socket, or database.
@Suite struct OverviewBroadcastDecisionTests {
    private static let interval = SpacesDeviceAPIServer.overviewMetadataCoalesceInterval

    @Test func identicalBytesAreSkippedRegardlessOfProjectionOrTiming() throws {
        let payload = makePayload(sessions: [makeSession()])
        let bytes = try encoded(payload)
        let projection = SpacesDeviceAPIServer.overviewStateProjection(payload)
        let decision = SpacesDeviceAPIServer.overviewBroadcastDecision(
            previousBytes: bytes, newBytes: bytes, previousProjection: projection, newProjection: projection, lastBroadcastAt: Date(), now: Date(),
            metadataCoalesceInterval: Self.interval)
        #expect(decision == .skip)
    }

    @Test func theFirstEverBroadcastAlwaysSendsImmediately() throws {
        let payload = makePayload(sessions: [makeSession()])
        let bytes = try encoded(payload)
        let projection = SpacesDeviceAPIServer.overviewStateProjection(payload)
        let decision = SpacesDeviceAPIServer.overviewBroadcastDecision(
            previousBytes: nil, newBytes: bytes, previousProjection: nil, newProjection: projection, lastBroadcastAt: nil, now: Date(),
            metadataCoalesceInterval: Self.interval)
        #expect(decision == .sendNow)
    }

    @Test func aStateChangeSendsImmediatelyEvenShortlyAfterTheLastPush() throws {
        let previous = makePayload(sessions: [makeSession(id: "session-1")])
        // A second live session appearing is row-shaped state, not metadata.
        let next = makePayload(sessions: [makeSession(id: "session-1"), makeSession(id: "session-2")])
        let now = Date()
        let decision = SpacesDeviceAPIServer.overviewBroadcastDecision(
            previousBytes: try encoded(previous), newBytes: try encoded(next),
            previousProjection: SpacesDeviceAPIServer.overviewStateProjection(previous),
            newProjection: SpacesDeviceAPIServer.overviewStateProjection(next), lastBroadcastAt: now.addingTimeInterval(-0.1), now: now,
            metadataCoalesceInterval: Self.interval)
        #expect(decision == .sendNow)
    }

    @Test func anAgentStatusChangeCountsAsState() throws {
        let previous = makePayload(codingAgentRows: [makeCodingAgentRow(activityState: .idle)])
        let next = makePayload(codingAgentRows: [makeCodingAgentRow(activityState: .spinning)])
        let now = Date()
        let decision = SpacesDeviceAPIServer.overviewBroadcastDecision(
            previousBytes: try encoded(previous), newBytes: try encoded(next),
            previousProjection: SpacesDeviceAPIServer.overviewStateProjection(previous),
            newProjection: SpacesDeviceAPIServer.overviewStateProjection(next), lastBroadcastAt: now.addingTimeInterval(-0.1), now: now,
            metadataCoalesceInterval: Self.interval)
        #expect(decision == .sendNow)
    }

    @Test func aDismissalOrFlagChangeCountsAsState() throws {
        let base = makePayload(codingAgentRows: [makeCodingAgentRow(activityState: .done)])
        let dismissed = SpacesDeviceOverviewPayload(
            workspaces: base.workspaces, sessions: base.sessions, daemonStatus: base.daemonStatus,
            dismissedAlertKeys: ["agent:agent:1:done:2026-01-01T00:00:00Z"])
        let flagged = SpacesDeviceOverviewPayload(
            workspaces: base.workspaces, sessions: base.sessions, daemonStatus: base.daemonStatus,
            comeBackLaterFlags: [SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "agent:1", flaggedAt: "2026-01-01T00:00:00Z")])
        let now = Date()
        for next in [dismissed, flagged] {
            let decision = SpacesDeviceAPIServer.overviewBroadcastDecision(
                previousBytes: try encoded(base), newBytes: try encoded(next),
                previousProjection: SpacesDeviceAPIServer.overviewStateProjection(base),
                newProjection: SpacesDeviceAPIServer.overviewStateProjection(next), lastBroadcastAt: now.addingTimeInterval(-0.1), now: now,
                metadataCoalesceInterval: Self.interval)
            #expect(decision == .sendNow)
        }
    }

    @Test func aBellCountsAsState() throws {
        let previous = makePayload(sessions: [makeSession(bellAt: nil)])
        let next = makePayload(sessions: [makeSession(bellAt: "2026-01-01T00:00:05Z")])
        let now = Date()
        let decision = SpacesDeviceAPIServer.overviewBroadcastDecision(
            previousBytes: try encoded(previous), newBytes: try encoded(next),
            previousProjection: SpacesDeviceAPIServer.overviewStateProjection(previous),
            newProjection: SpacesDeviceAPIServer.overviewStateProjection(next), lastBroadcastAt: now.addingTimeInterval(-0.1), now: now,
            metadataCoalesceInterval: Self.interval)
        #expect(decision == .sendNow)
    }

    @Test func aCodingAgentLiveTitleChangeIsMetadataOnlyAndSendsAtOnceWhenTheCoalesceWindowHasAlreadyElapsed() throws {
        let previous = makePayload(codingAgentRows: [makeCodingAgentRow(liveTitle: "npm run build")])
        let next = makePayload(codingAgentRows: [makeCodingAgentRow(liveTitle: "npm test")])
        let now = Date()
        let decision = SpacesDeviceAPIServer.overviewBroadcastDecision(
            previousBytes: try encoded(previous), newBytes: try encoded(next),
            previousProjection: SpacesDeviceAPIServer.overviewStateProjection(previous),
            newProjection: SpacesDeviceAPIServer.overviewStateProjection(next), lastBroadcastAt: now.addingTimeInterval(-Self.interval), now: now,
            metadataCoalesceInterval: Self.interval)
        #expect(decision == .sendNow)
    }

    @Test func aTerminalRowWorkingDirectoryChangeIsMetadataOnlyAndDefersWithinTheCoalesceWindow() throws {
        let previous = makePayload(terminalRows: [makeTerminalRow(workingDirectory: "/repo")])
        let next = makePayload(terminalRows: [makeTerminalRow(workingDirectory: "/repo/subdir")])
        let now = Date()
        let lastBroadcastAt = now.addingTimeInterval(-2)
        let decision = SpacesDeviceAPIServer.overviewBroadcastDecision(
            previousBytes: try encoded(previous), newBytes: try encoded(next),
            previousProjection: SpacesDeviceAPIServer.overviewStateProjection(previous),
            newProjection: SpacesDeviceAPIServer.overviewStateProjection(next), lastBroadcastAt: lastBroadcastAt, now: now,
            metadataCoalesceInterval: Self.interval)
        #expect(decision == .deferUntil(lastBroadcastAt.addingTimeInterval(Self.interval)))
    }

    @Test func aSessionLiveTitleAndCwdChangeIsMetadataOnly() throws {
        let previous = makePayload(sessions: [makeSession(liveTitle: "vim", workingDirectory: "/repo")])
        let next = makePayload(sessions: [makeSession(liveTitle: "vim main.swift", workingDirectory: "/repo/src")])
        let now = Date()
        let decision = SpacesDeviceAPIServer.overviewBroadcastDecision(
            previousBytes: try encoded(previous), newBytes: try encoded(next),
            previousProjection: SpacesDeviceAPIServer.overviewStateProjection(previous),
            newProjection: SpacesDeviceAPIServer.overviewStateProjection(next), lastBroadcastAt: now.addingTimeInterval(-Self.interval - 1), now: now,
            metadataCoalesceInterval: Self.interval)
        #expect(decision == .sendNow)
    }
}
