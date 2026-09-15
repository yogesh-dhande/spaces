import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import spacestestsupport
import workspacecore

@testable import spacesui

/// Covers what each cross-device cycling mode rotates over: which rows are in the set, the order they
/// come in, and the cursor keys that keep two workspaces' targets apart in one rotation.
@Suite struct WindowCycleModeTargetsTests {
    @Test func attentionHoldsWaitingAndDoneAgentsNewestStateChangeFirst() {
        let targets = WindowCycleModeTargets.targets(
            mode: .attention, devices: twoDeviceFixture(), openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: [])

        // Newest state change first, across both devices: mac "waiting" 10:05, linux "done" 10:03,
        // mac "done" 10:01. The spinning, idle, and exited rows are not waiting on anyone.
        #expect(targets.map { $0.target.agentWindow?.id } == ["agent-mac-waiting", "agent-linux-done", "agent-mac-done"])
    }

    @Test func attentionIsEmptyWhenNoAgentIsWaitingOrDone() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(
                        id: "w1",
                        agents: [
                            agentRow(id: "a-spin", workspaceID: "w1", state: .spinning, updatedAt: "2026-01-01T10:00:00Z"),
                            agentRow(id: "a-idle", workspaceID: "w1", state: .idle, updatedAt: "2026-01-01T10:00:00Z"),
                        ])
                ], sessions: []))

        let targets = WindowCycleModeTargets.targets(
            mode: .attention, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: [])

        #expect(targets.isEmpty)
    }

    @Test func allAgentsExcludesIdleAndExitedRows() {
        let targets = WindowCycleModeTargets.targets(
            mode: .allAgents, devices: twoDeviceFixture(), openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: [])

        // Spinning joins waiting and done; the idle row (a terminal no agent has started in) and the
        // exited row (an agent that is over) stay out.
        #expect(targets.map { $0.target.agentWindow?.id } == ["agent-mac-waiting", "agent-linux-spinning", "agent-linux-done", "agent-mac-done"])
    }

    @Test func agentRowWithoutASessionIsNotACycleTarget() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(
                        id: "w1",
                        agents: [
                            SpacesDeviceWorkspaceCodingAgentRow(
                                id: "row-a-waiting", workspaceID: "w1", name: "a-waiting", command: "claude", agentID: "a-waiting", sessionID: nil,
                                runState: .running, activityState: .waiting, updatedAt: "2026-01-01T10:00:00Z", canStop: true)
                        ])
                ], sessions: []))

        let targets = WindowCycleModeTargets.targets(
            mode: .attention, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: [])

        #expect(targets.isEmpty)
    }

    @Test func attentionCursorKeysStayDistinctAcrossWorkspacesAndDevices() {
        let sharedAgentID = "agent-1"
        let devices = [
            WindowCycleDeviceSnapshot(
                deviceID: "mac",
                overview: SpacesDeviceOverviewPayload(
                    workspaces: [
                        workspace(
                            id: "w1", agents: [agentRow(id: sharedAgentID, workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:00:00Z")]),
                        workspace(
                            id: "w2", agents: [agentRow(id: sharedAgentID, workspaceID: "w2", state: .waiting, updatedAt: "2026-01-01T10:00:00Z")]),
                    ], sessions: [])),
            WindowCycleDeviceSnapshot(
                deviceID: "linux",
                overview: SpacesDeviceOverviewPayload(
                    workspaces: [
                        workspace(
                            id: "w1", agents: [agentRow(id: sharedAgentID, workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:00:00Z")])
                    ], sessions: [])),
        ]

        let targets = WindowCycleModeTargets.targets(
            mode: .attention, devices: devices, openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: [])

        #expect(
            Set(targets.map(\.cursorKey)) == [
                "device:mac/workspace:w1/agent:agent-1", "device:mac/workspace:w2/agent:agent-1", "device:linux/workspace:w1/agent:agent-1",
            ])
        #expect(targets.map { ($0.deviceID, $0.workspaceID) }.count == 3)
    }

    @Test func openSessionsOrdersVisitedTargetsByRecencyAndUnvisitedInSidebarOrder() {
        let devices = [
            WindowCycleDeviceSnapshot(
                deviceID: "mac",
                overview: SpacesDeviceOverviewPayload(
                    workspaces: [
                        workspace(id: "w1", terminals: [terminalRow(id: "t-a", workspaceID: "w1", sessionID: "session-a", title: "a")]),
                        workspace(id: "w2", terminals: [terminalRow(id: "t-b", workspaceID: "w2", sessionID: "session-b", title: "b")]),
                    ], sessions: [])),
            WindowCycleDeviceSnapshot(
                deviceID: "linux",
                overview: SpacesDeviceOverviewPayload(
                    workspaces: [workspace(id: "w3", terminals: [terminalRow(id: "t-c", workspaceID: "w3", sessionID: "session-c", title: "c")])],
                    sessions: [])),
        ]

        let targets = WindowCycleModeTargets.targets(
            mode: .openSessions, devices: devices,
            openTerminalSessionIDsByWorkspace: ["w1": ["session-a"], "w2": ["session-b"], "w3": ["session-c"]], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:],
            // The linux terminal was visited most recently; the two Mac ones have never been visited,
            // so they follow in sidebar order.
            recentCursors: ["device:linux/workspace:w3/terminal:session-c"], retaining: [])

        #expect(
            targets.map(\.cursorKey) == [
                "device:linux/workspace:w3/terminal:session-c", "device:mac/workspace:w1/terminal:session-a",
                "device:mac/workspace:w2/terminal:session-b",
            ])
    }

    @Test func openSessionsHoldsOnlyPanesAndBrowserSessionsReportedOpen() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(
                        id: "w1", browserSessionURL: "http://localhost:3000",
                        terminals: [
                            terminalRow(id: "t-open", workspaceID: "w1", sessionID: "session-open", title: "open"),
                            terminalRow(id: "t-closed", workspaceID: "w1", sessionID: "session-closed", title: "closed"),
                        ])
                ], sessions: []))

        let targets = WindowCycleModeTargets.targets(
            mode: .openSessions, devices: [device], openTerminalSessionIDsByWorkspace: ["w1": ["session-open"]],
            openBrowserSessionsByWorkspace: ["w1": [BrowserSession(name: "docs", url: "http://localhost:3000")]],
            trackedBrowserWindowIDsByWorkspace: ["w1": [7]], recentCursors: [], retaining: [])

        #expect(
            targets.map(\.cursorKey) == ["device:mac/workspace:w1/browser:http://localhost:3000", "device:mac/workspace:w1/terminal:session-open"])
        // Only a browser target can be matched against a Chrome window, so only it carries the
        // workspace's tracked window ids.
        #expect(targets.map(\.trackedBrowserWindowIDs) == [[7], []])
    }

    // MARK: - Retention while a burst is live

    @Test func attentionKeepsTheAgentThatStartedWorkingMidBurst() {
        let burst = [agentCursor("a"), agentCursor("b"), agentCursor("c")]
        // The user landed on `a`, answered it, and it is working again with the newest state change of
        // the three. Attention alone would drop it mid-burst. The state changes also put `c` ahead of
        // `b` in the mode's own order, so a rebuilt rotation would visibly differ from the frozen one.
        let devices = [
            oneDevice(agents: [
                agentRow(id: "a", workspaceID: "w1", state: .spinning, updatedAt: "2026-01-01T10:09:00Z"),
                agentRow(id: "b", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:01:00Z"),
                agentRow(id: "c", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:02:00Z"),
            ])
        ]

        let targets = WindowCycleModeTargets.targets(
            mode: .attention, devices: devices, openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: burst)

        #expect(Set(targets.map(\.cursorKey)) == Set(burst))
        // Every frozen cursor is still a candidate, so the burst walks its own order and the next press
        // lands on `b`, the agent it would have landed on before the answer.
        #expect(landing(after: burst[0], in: targets, session: session(burst)) == burst[1])
    }

    @Test func allAgentsKeepsTheAgentThatExitedMidBurst() {
        let burst = [agentCursor("a"), agentCursor("b"), agentCursor("c")]
        // An exited agent is not in All agents, and exiting is how a target leaves that set mid-burst:
        // `waiting` and `done` are in the set already, so a state change to either changes nothing.
        let devices = [
            oneDevice(agents: [
                agentRow(id: "a", workspaceID: "w1", state: .exited, updatedAt: "2026-01-01T10:09:00Z"),
                agentRow(id: "b", workspaceID: "w1", state: .spinning, updatedAt: "2026-01-01T10:01:00Z"),
                agentRow(id: "c", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:02:00Z"),
            ])
        ]

        let targets = WindowCycleModeTargets.targets(
            mode: .allAgents, devices: devices, openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: burst)

        #expect(Set(targets.map(\.cursorKey)) == Set(burst))
        #expect(landing(after: burst[0], in: targets, session: session(burst)) == burst[1])
    }

    @Test func anAgentWhoseRowVanishedMidBurstLeavesTheRotation() {
        let burst = [agentCursor("a"), agentCursor("b"), agentCursor("c")]
        // `b`'s row is gone from the overview, so there is nothing left to focus and retention cannot
        // bring it back.
        let devices = [
            oneDevice(agents: [
                agentRow(id: "a", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:01:00Z"),
                agentRow(id: "c", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:05:00Z"),
            ])
        ]

        let targets = WindowCycleModeTargets.targets(
            mode: .attention, devices: devices, openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: burst)

        #expect(targets.map(\.cursorKey) == [agentCursor("c"), agentCursor("a")])
        // A frozen cursor is missing, so the rotation is rebuilt around what is left, the same as a
        // workspace rotation whose pane closed: the current target leads, and `c` follows it even though
        // its newer state change puts it first in the mode's own order.
        let ordering = WorkspaceWindowCycle.cycleOrdering(
            cursors: targets.map(\.cursorKey), currentIndex: targets.firstIndex { $0.cursorKey == burst[0] }, session: session(burst),
            recentCursors: [])
        #expect(ordering.indices.map { targets[$0].cursorKey } == [agentCursor("a"), agentCursor("c")])
    }

    @Test func withoutALiveBurstTheModeFilterApplies() {
        let devices = [
            oneDevice(agents: [
                agentRow(id: "a", workspaceID: "w1", state: .spinning, updatedAt: "2026-01-01T10:09:00Z"),
                agentRow(id: "b", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:02:00Z"),
            ])
        ]

        let targets = WindowCycleModeTargets.targets(
            mode: .attention, devices: devices, openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: [])

        // Nothing is being walked, so a working agent is simply not waiting on the user.
        #expect(targets.map(\.cursorKey) == [agentCursor("b")])
    }

    // MARK: - Sidebar visibility

    /// A global mode lists rows the user can be sent to, and a hidden workspace has no sidebar row, so
    /// its agents stay out however loudly they are asking for an answer.
    @Test func attentionSkipsAWaitingAgentInAHiddenWorkspace() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(
                        id: "shown", agents: [agentRow(id: "a-shown", workspaceID: "shown", state: .waiting, updatedAt: "2026-01-01T10:00:00Z")]),
                    workspace(
                        id: "hidden", isHidden: true,
                        agents: [agentRow(id: "a-hidden", workspaceID: "hidden", state: .waiting, updatedAt: "2026-01-01T10:05:00Z")]),
                ], sessions: []))

        let targets = WindowCycleModeTargets.targets(
            mode: .attention, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: [])

        // The hidden workspace's agent has the newer state change, so it would lead the mode's order:
        // its absence is the visibility rule, not the ordering.
        #expect(targets.map { $0.target.agentWindow?.id } == ["a-shown"])
    }

    /// Hiding a project suppresses its workspaces without touching their own flags, so a pane in a
    /// workspace under a hidden project is out of the set even though the workspace is not hidden itself.
    @Test func openSessionsSkipsAnOpenPaneInAHiddenProjectsWorkspace() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac",
            overview: SpacesDeviceOverviewPayload(
                projects: [project(id: "shown-project", isHidden: false), project(id: "hidden-project", isHidden: true)],
                workspaces: [
                    workspace(
                        id: "shown", projectID: "shown-project",
                        terminals: [terminalRow(id: "t-shown", workspaceID: "shown", sessionID: "session-shown", title: "shown")]),
                    workspace(
                        id: "hidden", projectID: "hidden-project",
                        terminals: [terminalRow(id: "t-hidden", workspaceID: "hidden", sessionID: "session-hidden", title: "hidden")]),
                ], sessions: []))

        let targets = WindowCycleModeTargets.targets(
            mode: .openSessions, devices: [device], openTerminalSessionIDsByWorkspace: ["shown": ["session-shown"], "hidden": ["session-hidden"]],
            openBrowserSessionsByWorkspace: [:], trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: [])

        #expect(targets.map(\.cursorKey) == ["device:mac/workspace:shown/terminal:session-shown"])
    }

    /// Retention keeps a frozen burst walking targets the mode's filter dropped, but it cannot reach into
    /// a workspace that left the sidebar: a hide mid-burst takes the target out like a vanished row.
    @Test func aRetainedTargetWhoseWorkspaceIsHiddenMidBurstLeavesTheRotation() {
        let burst = ["device:mac/workspace:shown/agent:a-shown", "device:mac/workspace:hidden/agent:a-hidden"]
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(
                        id: "shown", agents: [agentRow(id: "a-shown", workspaceID: "shown", state: .waiting, updatedAt: "2026-01-01T10:00:00Z")]),
                    workspace(
                        id: "hidden", isHidden: true,
                        agents: [agentRow(id: "a-hidden", workspaceID: "hidden", state: .waiting, updatedAt: "2026-01-01T10:05:00Z")]),
                ], sessions: []))

        let targets = WindowCycleModeTargets.targets(
            mode: .attention, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: burst)

        #expect(targets.map(\.cursorKey) == [burst[0]])
    }

    // MARK: - Reachability

    /// A paired device the sidebar can no longer reach keeps its last-known overview (see
    /// `WindowCycleDeviceSnapshot`), so a waiting agent on it is still in the payload. Without an open
    /// pane to land on, a cycle press would hit `openOrFocusTerminalPane`'s modal refusal, so the
    /// target, and the row's count, leave it out.
    @Test func anUnreachableDevicesWaitingAgentWithoutAnOpenPaneIsNotATarget() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "linux",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(id: "w1", agents: [agentRow(id: "a-offline", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:00:00Z")])
                ], sessions: []), isReachable: false)

        let targets = WindowCycleModeTargets.targets(
            mode: .attention, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: [])

        #expect(targets.isEmpty)
    }

    /// The same unreachable device's agent, but its pane is already open locally: focusing it needs no
    /// round trip to the offline device, so it stays a target.
    @Test func anUnreachableDevicesWaitingAgentWithAnOpenPaneStaysATarget() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "linux",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(id: "w1", agents: [agentRow(id: "a-offline", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:00:00Z")])
                ], sessions: []), isReachable: false)

        let targets = WindowCycleModeTargets.targets(
            mode: .attention, devices: [device], openTerminalSessionIDsByWorkspace: ["w1": ["session-a-offline"]],
            openBrowserSessionsByWorkspace: [:], trackedBrowserWindowIDsByWorkspace: [:], recentCursors: [], retaining: [])

        #expect(targets.map { $0.target.agentWindow?.id } == ["a-offline"])
    }

    // MARK: - Fixtures

    /// Two devices whose agents sit in every activity state, with state-change times that make the
    /// expected order differ from sidebar order.
    private func twoDeviceFixture() -> [WindowCycleDeviceSnapshot] {
        [
            WindowCycleDeviceSnapshot(
                deviceID: "mac",
                overview: SpacesDeviceOverviewPayload(
                    workspaces: [
                        workspace(
                            id: "w1",
                            agents: [
                                agentRow(id: "agent-mac-done", workspaceID: "w1", state: .done, updatedAt: "2026-01-01T10:01:00Z"),
                                agentRow(id: "agent-mac-waiting", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:05:00Z"),
                                agentRow(id: "agent-mac-idle", workspaceID: "w1", state: .idle, updatedAt: "2026-01-01T10:06:00Z"),
                            ])
                    ], sessions: [])),
            WindowCycleDeviceSnapshot(
                deviceID: "linux",
                overview: SpacesDeviceOverviewPayload(
                    workspaces: [
                        workspace(
                            id: "w2",
                            agents: [
                                agentRow(id: "agent-linux-spinning", workspaceID: "w2", state: .spinning, updatedAt: "2026-01-01T10:04:00Z"),
                                agentRow(id: "agent-linux-done", workspaceID: "w2", state: .done, updatedAt: "2026-01-01T10:03:00Z"),
                                agentRow(id: "agent-linux-exited", workspaceID: "w2", state: .exited, updatedAt: "2026-01-01T10:07:00Z"),
                            ])
                    ], sessions: [])),
        ]
    }

    private func oneDevice(agents: [SpacesDeviceWorkspaceCodingAgentRow]) -> WindowCycleDeviceSnapshot {
        WindowCycleDeviceSnapshot(
            deviceID: "mac", overview: SpacesDeviceOverviewPayload(workspaces: [workspace(id: "w1", agents: agents)], sessions: []))
    }

    private func agentCursor(_ agentID: String) -> String { "device:mac/workspace:w1/agent:\(agentID)" }

    /// A burst frozen on its first target, as `WindowCycleState` records it.
    private func session(_ orderedCursors: [String]) -> WorkspaceWindowCycle.CycleSession {
        WorkspaceWindowCycle.CycleSession(orderedCursors: orderedCursors, currentIndex: 0, lastUsedAt: Date())
    }

    /// Where the next press lands when the burst is sitting on `cursor`.
    private func landing(after cursor: String, in targets: [WindowCycleTarget], session: WorkspaceWindowCycle.CycleSession) -> String? {
        let ordering = WorkspaceWindowCycle.cycleOrdering(
            cursors: targets.map(\.cursorKey), currentIndex: targets.firstIndex { $0.cursorKey == cursor }, session: session, recentCursors: [])
        let nextIndex = WorkspaceWindowCycle.nextIndex(orderedCount: ordering.indices.count, orderedCurrentIndex: ordering.currentIndex, delta: 1)
        guard ordering.indices.indices.contains(nextIndex) else { return nil }
        return targets[ordering.indices[nextIndex]].cursorKey
    }

    private func project(id: String, isHidden: Bool) -> SpacesDeviceProjectSummary {
        SpacesDeviceProjectSummary(id: id, name: id, dir: "/tmp/\(id)", isGitRepo: true, defaultBranch: "main", isHidden: isHidden)
    }

    private func workspace(
        id: String, projectID: String = "project", isHidden: Bool = false, browserSessionURL: String? = nil,
        agents: [SpacesDeviceWorkspaceCodingAgentRow] = [], terminals: [SpacesDeviceWorkspaceTerminalRow] = []
    ) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: projectID, projectName: projectID, branch: id, baseBranch: "main", dir: "/tmp/\(id)", isRunning: true,
            isHidden: isHidden, isDefault: false, sessionCount: agents.count + terminals.count,
            config: SpacesDeviceWorkspaceConfig(
                resolvedBrowserSessions: browserSessionURL.map { [SpacesDeviceBrowserSession(name: "docs", url: $0)] } ?? []),
            codingAgentRows: agents, terminalRows: terminals)
    }

    private func agentRow(id: String, workspaceID: String, state: SpacesDeviceCodingAgentActivityState, updatedAt: String?)
        -> SpacesDeviceWorkspaceCodingAgentRow
    {
        SpacesDeviceWorkspaceCodingAgentRow(
            id: "row-\(id)", workspaceID: workspaceID, name: id, command: "claude", agentID: id, sessionID: "session-\(id)", runState: .running,
            activityState: state, updatedAt: updatedAt, canStop: true)
    }

    private func terminalRow(id: String, workspaceID: String, sessionID: String, title: String) -> SpacesDeviceWorkspaceTerminalRow {
        SpacesDeviceWorkspaceTerminalRow(
            id: id, workspaceID: workspaceID, title: title, workingDirectory: "/tmp/\(workspaceID)", sessionID: sessionID, runState: .running,
            canOpenTerminal: true)
    }
}
