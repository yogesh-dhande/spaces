import Foundation
import Testing
import spacesterminalcore

@testable import spacesdevicecore

/// The alert candidates a device overview describes: which sources alert, what identity each carries, and
/// which are left to the consumer to filter.
@Suite struct SpacesDeviceAlertsTests {
    @Test func agentWaitingAndDoneAlertWithKeysThatChangeWithStateAndTime() throws {
        let overview = Fixture.overview(
            workspaces: [
                Fixture.workspace(
                    agents: [
                        Fixture.agent(id: "a-wait", sessionID: "s1", state: .waiting, updatedAt: "2026-07-14T09:00:00Z"),
                        Fixture.agent(id: "a-done", sessionID: "s2", state: .done, updatedAt: "2026-07-14T09:05:00.250Z"),
                        Fixture.agent(id: "a-busy", sessionID: "s3", state: .spinning, updatedAt: "2026-07-14T09:06:00Z"),
                        Fixture.agent(id: "a-gone", sessionID: "s4", state: .exited, updatedAt: "2026-07-14T09:07:00Z"),
                    ])
            ])
        let candidates = overview.alertCandidates()
        #expect(
            candidates.map(\.key).sorted() == [
                "agent:a-done:done:2026-07-14T09:05:00.250Z", "agent:a-wait:waiting:2026-07-14T09:00:00Z",
            ])
        let waiting = try #require(candidates.first { $0.kind == .agentWaiting })
        #expect(waiting.workspaceID == "w1")
        #expect(waiting.sessionID == "s1")
        #expect(waiting.subjectID == "a-wait")
        #expect(waiting.date != nil)
        #expect(!waiting.clearsOnVisit)
        #expect(try #require(candidates.first { $0.kind == .agentDone }).clearsOnVisit)
    }

    @Test func exitedProcessAlertsEvenWhenItsWorkspaceIsStopped() throws {
        let overview = Fixture.overview(
            workspaces: [
                Fixture.workspace(
                    isRunning: false,
                    processes: [
                        Fixture.process(id: "p-exit", sessionID: "s1", runState: .exited, exitedAt: "2026-07-14T09:00:00Z"),
                        Fixture.process(id: "p-live", sessionID: "s2", runState: .running, exitedAt: nil),
                        Fixture.process(id: "p-never", sessionID: nil, runState: .notStarted, exitedAt: nil),
                    ])
            ])
        let candidates = overview.alertCandidates()
        #expect(candidates.map(\.key) == ["process:p-exit:2026-07-14T09:00:00Z"])
        #expect(candidates[0].kind == .processExited)
        #expect(candidates[0].clearsOnVisit)
    }

    @Test func aSourceWithoutAUsableTimestampIsSkipped() {
        let overview = Fixture.overview(
            workspaces: [
                Fixture.workspace(
                    processes: [Fixture.process(id: "p", sessionID: "s2", runState: .exited, exitedAt: "not a date")],
                    agents: [Fixture.agent(id: "a", sessionID: "s1", state: .done, updatedAt: nil)])
            ],
            sessions: [Fixture.session(id: "loose", state: .exited, updatedAt: "")])
        #expect(overview.alertCandidates().isEmpty)
    }

    @Test func terminalRowAlertsFromItsSessionAndALooseSessionAlertsOnlyWhenNoRowShowsIt() throws {
        let overview = Fixture.overview(
            workspaces: [
                Fixture.workspace(
                    terminals: [
                        Fixture.terminal(id: "t-exit", sessionID: "s-exit", runState: .exited),
                        Fixture.terminal(id: "t-fail", sessionID: "s-fail", runState: .exited),
                    ],
                    agents: [Fixture.agent(id: "a", sessionID: "s-agent", state: .idle, updatedAt: "2026-07-14T09:00:00Z")])
            ],
            sessions: [
                Fixture.session(id: "s-exit", state: .exited, updatedAt: "2026-07-14T10:00:00Z"),
                Fixture.session(id: "s-fail", state: .failed, updatedAt: "2026-07-14T10:01:00Z"),
                // Shown by an agent row, so it never alerts a second time as a loose session.
                Fixture.session(id: "s-agent", state: .exited, updatedAt: "2026-07-14T10:02:00Z"),
                Fixture.session(id: "s-loose", state: .failed, updatedAt: "2026-07-14T10:03:00Z"),
                Fixture.session(id: "s-running", state: .running, updatedAt: "2026-07-14T10:04:00Z"),
                // A row-backed session record that no row references is not a loose live session.
                Fixture.session(id: "s-process-kind", state: .exited, updatedAt: "2026-07-14T10:05:00Z", rowKind: .process),
            ])
        let byKey = Dictionary(uniqueKeysWithValues: overview.alertCandidates().map { ($0.key, $0) })
        #expect(
            Set(byKey.keys) == [
                "terminal:t-exit:exited:2026-07-14T10:00:00Z", "terminal:t-fail:failed:2026-07-14T10:01:00Z",
                "session:s-loose:failed:2026-07-14T10:03:00Z",
            ])
        #expect(byKey["terminal:t-exit:exited:2026-07-14T10:00:00Z"]?.kind == .terminalExited)
        #expect(byKey["session:s-loose:failed:2026-07-14T10:03:00Z"]?.kind == .terminalFailed)
        #expect(byKey["session:s-loose:failed:2026-07-14T10:03:00Z"]?.sessionID == "s-loose")
    }

    @Test func hiddenWorkspacesAndTheirBellsAreIncluded() throws {
        let overview = Fixture.overview(
            workspaces: [
                Fixture.workspace(id: "w-hidden", isHidden: true, agents: [Fixture.agent(id: "a", sessionID: "s1", state: .done, updatedAt: "2026-07-14T09:00:00Z")])
            ],
            sessions: [Fixture.session(id: "s1", workspaceID: "w-hidden", state: .running, updatedAt: "2026-07-14T09:00:00Z", bellAt: "2026-07-14T09:30:00.500Z")])
        let candidates = overview.alertCandidates()
        #expect(Set(candidates.map(\.kind)) == [.agentDone, .bell])
        let bell = try #require(candidates.first { $0.kind == .bell })
        #expect(bell.key == "bell:s1:2026-07-14T09:30:00.500Z")
        #expect(bell.workspaceID == "w-hidden")
        #expect(!bell.clearsOnVisit)
    }

    @Test func aBellForASessionWhoseWorkspaceIsGoneIsNotACandidate() {
        let overview = Fixture.overview(
            workspaces: [Fixture.workspace()],
            sessions: [Fixture.session(id: "orphan", workspaceID: "deleted", state: .running, updatedAt: "2026-07-14T09:00:00Z", bellAt: "2026-07-14T09:30:00Z")])
        #expect(overview.alertCandidates().isEmpty)
    }

    @Test func onlyFailedAndTimedOutAutomationRunsAlert() throws {
        let overview = Fixture.overview(
            workspaces: [],
            runs: [
                Fixture.run(id: "r-fail", status: "failed", endedAt: "2026-07-14T09:00:00Z"),
                Fixture.run(id: "r-time", status: "timed_out", endedAt: nil),
                Fixture.run(id: "r-ok", status: "succeeded", endedAt: "2026-07-14T09:00:00Z"),
                Fixture.run(id: "r-live", status: "running", endedAt: nil),
            ])
        let candidates = overview.alertCandidates()
        #expect(candidates.map(\.key).sorted() == ["automationrun:r-fail:failed", "automationrun:r-time:timed_out"])
        #expect(candidates.allSatisfy { $0.workspaceID == nil })
        #expect(Set(candidates.map(\.kind)) == [.automationRunFailed, .automationRunTimedOut])
        #expect(candidates.allSatisfy { !$0.clearsOnVisit })
    }

    @Test func comeBackLaterFlagsAlertOnlyForRowsTheOverviewStillLists() throws {
        let flags = [
            SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "a", flaggedAt: "2026-07-14T09:00:00Z"),
            SpacesDeviceComeBackLaterFlag(rowKind: .process, rowID: "p-never", flaggedAt: "2026-07-14T09:01:00Z"),
            SpacesDeviceComeBackLaterFlag(rowKind: .terminal, rowID: "gone", flaggedAt: "2026-07-14T09:02:00Z"),
        ]
        let overview = Fixture.overview(
            workspaces: [
                Fixture.workspace(
                    processes: [Fixture.process(id: "p-never", sessionID: nil, runState: .running, exitedAt: nil)],
                    agents: [Fixture.agent(id: "a", sessionID: "s1", state: .idle, updatedAt: "2026-07-14T08:00:00Z")])
            ], flags: flags)
        let candidates = overview.alertCandidates()
        #expect(candidates.map(\.key).sorted() == ["comebacklater:agent:a", "comebacklater:process:p-never"])
        let agentFlag = try #require(candidates.first { $0.key == "comebacklater:agent:a" })
        #expect(agentFlag.kind == .comeBackLater)
        #expect(agentFlag.sessionID == "s1")
        #expect(agentFlag.workspaceID == "w1")
        #expect(agentFlag.date == GhosttyRemoteSessionStateTimestamp.date(from: "2026-07-14T09:00:00Z"))
        #expect(!agentFlag.clearsOnVisit)
    }

    @Test func reconcilingKeepsOnlyCurrentDismissalsAndFlagsOnExistingRows() {
        let overview = Fixture.overview(
            workspaces: [Fixture.workspace(agents: [Fixture.agent(id: "a", sessionID: "s1", state: .done, updatedAt: "2026-07-14T09:00:00Z")])],
            dismissed: ["agent:a:done:2026-07-14T09:00:00Z", "agent:a:done:2026-07-13T09:00:00Z"],
            flags: [
                SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "a", flaggedAt: "2026-07-14T09:00:00Z"),
                SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "gone", flaggedAt: "2026-07-14T09:00:00Z"),
            ])
        let reconciled = overview.reconcilingAlertState()
        #expect(reconciled.dismissedAlertKeys == ["agent:a:done:2026-07-14T09:00:00Z"])
        #expect(reconciled.comeBackLaterFlags.map(\.rowID) == ["a"])
    }

    @Test func flagAlertKeysRoundTripThroughTheirRowReference() {
        let flag = SpacesDeviceComeBackLaterFlag(rowKind: .process, rowID: "ws:process:web", flaggedAt: "2026-07-14T09:00:00Z")
        let reference = SpacesDeviceComeBackLaterFlag.rowReference(fromAlertKey: flag.alertKey)
        #expect(reference?.rowKind == .process)
        #expect(reference?.rowID == "ws:process:web")
        #expect(SpacesDeviceComeBackLaterFlag.rowReference(fromAlertKey: "agent:a:done:x") == nil)
    }

    @Test func overviewDecodesWithoutTheAlertStateFields() throws {
        let encoded = try JSONEncoder().encode(Fixture.overview(workspaces: [Fixture.workspace()]))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "dismissedAlertKeys")
        object.removeValue(forKey: "comeBackLaterFlags")
        let decoded = try JSONDecoder().decode(SpacesDeviceOverviewPayload.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.dismissedAlertKeys.isEmpty)
        #expect(decoded.comeBackLaterFlags.isEmpty)
    }
}

/// Overview fixtures shared with the alert-mutation tests through copy: kept small and explicit.
private enum Fixture {
    static func overview(
        workspaces: [SpacesDeviceWorkspaceSummary], sessions: [SpacesDeviceTerminalSessionSummary] = [],
        runs: [TerminalServiceAutomationRunSummary] = [], dismissed: [String] = [], flags: [SpacesDeviceComeBackLaterFlag] = []
    ) -> SpacesDeviceOverviewPayload {
        SpacesDeviceOverviewPayload(
            workspaces: workspaces, sessions: sessions,
            daemonStatus: TerminalServiceDaemonStatus(version: "test", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0),
            automationRuns: runs, dismissedAlertKeys: dismissed, comeBackLaterFlags: flags)
    }

    static func workspace(
        id: String = "w1", isRunning: Bool = true, isHidden: Bool = false, terminals: [SpacesDeviceWorkspaceTerminalRow] = [],
        processes: [SpacesDeviceWorkspaceProcessRow] = [], agents: [SpacesDeviceWorkspaceCodingAgentRow] = []
    ) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: "project-1", projectName: "Project", branch: "main", baseBranch: nil, dir: "/tmp/\(id)", isRunning: isRunning,
            isHidden: isHidden, isDefault: false, hasTrackedRuntimeIndicators: false, processRows: processes, codingAgentRows: agents,
            terminalRows: terminals)
    }

    static func agent(id: String, sessionID: String?, state: SpacesDeviceCodingAgentActivityState, updatedAt: String?)
        -> SpacesDeviceWorkspaceCodingAgentRow
    {
        SpacesDeviceWorkspaceCodingAgentRow(
            id: id, workspaceID: "w1", name: id, command: "claude", agentID: id, sessionID: sessionID, runState: .running, activityState: state,
            updatedAt: updatedAt, brief: nil, briefUpdatedAt: nil, canStop: true)
    }

    static func process(id: String, sessionID: String?, runState: SpacesDeviceRunState, exitedAt: String?) -> SpacesDeviceWorkspaceProcessRow {
        SpacesDeviceWorkspaceProcessRow(
            id: id, workspaceID: "w1", name: id, command: "npm run dev", processID: id, sessionID: sessionID, runState: runState, exitedAt: exitedAt,
            canRun: true, canStop: false, canRestart: false)
    }

    static func terminal(id: String, sessionID: String?, runState: SpacesDeviceRunState) -> SpacesDeviceWorkspaceTerminalRow {
        SpacesDeviceWorkspaceTerminalRow(
            id: id, workspaceID: "w1", title: id, workingDirectory: "/tmp", sessionID: sessionID, runState: runState, canOpenTerminal: true)
    }

    static func session(
        id: String, workspaceID: String = "w1", state: TerminalSessionState, updatedAt: String,
        rowKind: SpacesDeviceTerminalSessionRowKind = .liveSession, bellAt: String? = nil
    ) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: id, workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, state: state, backend: .ghosttyEmbedded,
            lifetimePolicy: .persistent, servicePID: 1, childPID: nil, workspaceID: workspaceID, workspaceTitle: nil, projectID: nil,
            projectName: nil, createdAt: "2026-07-14T08:00:00Z", updatedAt: updatedAt, isControlAvailable: false, isSubscriptionAvailable: false,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: rowKind, bellAt: bellAt)
    }

    static func run(id: String, status: String, endedAt: String?) -> TerminalServiceAutomationRunSummary {
        TerminalServiceAutomationRunSummary(
            id: id, automationID: "auto", automationName: "Nightly", kind: "script", status: status, trigger: "manual", skipReason: nil,
            exitCode: nil, terminalSessionID: nil, startedAt: nil, endedAt: endedAt, createdAt: "2026-07-14T08:30:00Z")
    }
}
