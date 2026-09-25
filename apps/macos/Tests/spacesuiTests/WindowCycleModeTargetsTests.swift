import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import spacestestsupport
import workspacecore

@testable import spacesui

/// Covers what each cross-device cycling mode rotates over: which rows are in the set, the order they
/// come in, and the cursor keys that keep two workspaces' targets apart in one rotation.
@Suite struct WindowCycleModeTargetsTests {
    @Test func alertsHoldsWaitingAndDoneAgentsNewestAlertFirst() {
        let targets = WindowCycleModeTargets.targets(
            mode: .alerts, devices: twoDeviceFixture(), openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        // Newest alert first, across both devices: mac "waiting" 10:05, linux "done" 10:03, mac "done"
        // 10:01. The spinning, idle, and exited rows raise no alert, so the Alerts pane does not list
        // them and neither does this rotation.
        #expect(targets.map { $0.target.agentWindow?.id } == ["agent-mac-waiting", "agent-linux-done", "agent-mac-done"])
    }

    @Test func alertsIsEmptyWhenNothingIsAlerting() {
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
            mode: .alerts, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        #expect(targets.isEmpty)
    }

    @Test func alertsHoldsEveryAlertingRowWithAWindowNewestEventFirst() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(
                        id: "w1", processes: [exitedProcessRow(id: "web", workspaceID: "w1", exitedAt: "2026-01-01T10:02:00Z")],
                        agents: [agentRow(id: "a-waiting", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:04:00Z")],
                        terminals: [terminalRow(id: "t-bell", workspaceID: "w1", sessionID: "session-bell", title: "build")])
                ], sessions: [sessionSummary(id: "session-bell", workspaceID: "w1", bellAt: "2026-01-01T10:06:00Z")]))

        let targets = WindowCycleModeTargets.targets(
            mode: .alerts, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        // The three alert kinds that name a window, newest event first: the bell at 10:06, the waiting
        // agent at 10:04, the process that exited at 10:02. Each lands on the window its pane row focuses.
        #expect(
            targets.map(\.cursorKey) == [
                "device:mac/workspace:w1/terminal:session-bell", "device:mac/workspace:w1/agent:a-waiting", "device:mac/workspace:w1/process:web",
            ])
    }

    @Test func alertsCountsASharedProcessAgentSessionOnce() {
        // A configured process whose command runs a coding agent has both a `running_processes` row and
        // an `agent_sessions` row naming the same terminal (docs/implementation.md, "A stop closes each
        // session id exactly once"), so the process row and the agent row here share one session id and
        // both alert: the agent is waiting, and its terminal also rang a bell.
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(
                        id: "w1", processes: [runningProcessRow(id: "claude", workspaceID: "w1", sessionID: "session-shared")],
                        agents: [
                            agentRow(
                                id: "a-waiting", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:04:00Z", sessionID: "session-shared")
                        ])
                ], sessions: [sessionSummary(id: "session-shared", workspaceID: "w1", bellAt: "2026-01-01T10:06:00Z")]))

        let targets = WindowCycleModeTargets.targets(
            mode: .alerts, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        // One pane, one target: the bell is the newer alert but the agent target is the pane's identity,
        // exactly as Workspace mode represents this shared session (`AppKitController.workspaceShortcutTargets`
        // drops the agent-claimed process entry, leaving only the agent target).
        #expect(targets.count == 1)
        #expect(targets.first?.cursorKey == "device:mac/workspace:w1/agent:a-waiting")
    }

    @Test func alertsResolvesAnExitedProcessSharingASessionWithAnAgentThroughTheAgentTarget() {
        // A configured process runs a coding agent's command; once that command exits, `running_processes`
        // keeps an exited row for it while `agent_sessions` keeps the agent row, both naming the same
        // terminal session (docs/implementation.md, "A stop closes each session id exactly once"). The
        // agent row's own state (`.exited`) raises no alert of its own (`AlertsController
        // .buildOverviewAlertsGroups` only builds an agent entry for `.waiting`/`.done`), so the process's
        // exited alert is the only alert on this pane. `AppKitController.workspaceShortcutTargets` still
        // drops the process's own target in favor of the agent's, since their session is agent-claimed, so
        // this alert must resolve through the process row's own session id rather than through a
        // `.process` target that no longer exists.
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(
                        id: "w1",
                        processes: [exitedProcessRow(id: "claude", workspaceID: "w1", exitedAt: "2026-01-01T10:02:00Z", sessionID: "session-shared")],
                        agents: [
                            agentRow(
                                id: "a-exited", workspaceID: "w1", state: .exited, updatedAt: "2026-01-01T09:00:00Z", sessionID: "session-shared")
                        ])
                ], sessions: []))

        let targets = WindowCycleModeTargets.targets(
            mode: .alerts, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        // One target, the agent's, since the process's own target was dropped for the shared session; the
        // count and the rotation must not lose this pane just because its only alert named an excluded
        // target kind.
        #expect(targets.count == 1)
        #expect(targets.first?.cursorKey == "device:mac/workspace:w1/agent:a-exited")
    }

    @Test func alertsSkipsARowWhoseAlertIsDismissed() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(
                        id: "w1",
                        agents: [
                            agentRow(id: "a-dismissed", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:05:00Z"),
                            agentRow(id: "a-alerting", workspaceID: "w1", state: .done, updatedAt: "2026-01-01T10:01:00Z"),
                        ])
                ], sessions: []))

        let targets = WindowCycleModeTargets.targets(
            mode: .alerts, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [alertID(in: device, workspaceID: "w1", agentID: "a-dismissed")],
            recentCursors: [], retaining: [])

        // The dismissed agent has the newer state change, so it would lead the order: its absence is the
        // pane's dismissal, which the rotation reads the same way the pane does.
        #expect(targets.map { $0.target.agentWindow?.id } == ["a-alerting"])
    }

    @Test func alertsSkipsAFailedAutomationRun() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac",
            overview: SpacesDeviceOverviewPayload(
                projects: [],
                workspaces: [workspace(id: "w1", terminals: [terminalRow(id: "t-run", workspaceID: "w1", sessionID: "session-run", title: "run")])],
                sessions: [sessionSummary(id: "session-run", workspaceID: "w1")], retainedTerminalSessionIDs: [],
                workspaceIDsWithTeardownInFlight: [], daemonStatus: .testStatus, automations: [],
                automationRuns: [
                    TerminalServiceAutomationRunSummary(
                        id: "run-1", automationID: "automation-1", automationName: "Nightly", kind: "script", status: "failed", trigger: "schedule",
                        skipReason: nil, exitCode: 1, terminalSessionID: "session-run", workspaceID: "w1", startedAt: "2026-01-01T10:00:00Z",
                        endedAt: "2026-01-01T10:09:00Z", createdAt: "2026-01-01T10:00:00Z")
                ]))

        let targets = WindowCycleModeTargets.targets(
            mode: .alerts, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        // The run's card deep-links to the Runs tab instead of focusing a window, so it stays in the pane
        // and out of the rotation, even though the session it ran in is still on the workspace.
        #expect(targets.isEmpty)
    }

    @Test func allAgentsHoldsEveryAgentThatHasNotExited() {
        let targets = WindowCycleModeTargets.targets(
            mode: .allAgents, devices: twoDeviceFixture(), openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        // Idle and spinning join waiting and done: an idle agent is launched and waiting for its first
        // prompt, which is a terminal the user has reason to reach. Only the exited row, an agent that is
        // over, stays out.
        #expect(
            targets.map { $0.target.agentWindow?.id } == [
                "agent-mac-idle", "agent-mac-waiting", "agent-linux-spinning", "agent-linux-done", "agent-mac-done",
            ])
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
            mode: .alerts, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        #expect(targets.isEmpty)
    }

    @Test func alertsCursorKeysStayDistinctAcrossWorkspacesAndDevices() {
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
            mode: .alerts, devices: devices, openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

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
            dismissedAlertIDs: [], recentCursors: ["device:linux/workspace:w3/terminal:session-c"], retaining: [])

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
            trackedBrowserWindowIDsByWorkspace: ["w1": [7]], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        #expect(
            targets.map(\.cursorKey) == ["device:mac/workspace:w1/browser:http://localhost:3000", "device:mac/workspace:w1/terminal:session-open"])
        // Only a browser target can be matched against a Chrome window, so only it carries the
        // workspace's tracked window ids.
        #expect(targets.map(\.trackedBrowserWindowIDs) == [[7], []])
    }

    // MARK: - Retention while a burst is live

    @Test func alertsKeepsTheAgentThatStartedWorkingMidBurst() {
        let burst = [agentCursor("a"), agentCursor("b"), agentCursor("c")]
        // The user landed on `a`, answered it, and it is working again with the newest state change of
        // the three, so its alert is gone. The Alerts filter alone would drop it mid-burst. The state changes also put `c` ahead of
        // `b` in the mode's own order, so a rebuilt rotation would visibly differ from the frozen one.
        let devices = [
            oneDevice(agents: [
                agentRow(id: "a", workspaceID: "w1", state: .spinning, updatedAt: "2026-01-01T10:09:00Z"),
                agentRow(id: "b", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:01:00Z"),
                agentRow(id: "c", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:02:00Z"),
            ])
        ]

        let targets = WindowCycleModeTargets.targets(
            mode: .alerts, devices: devices, openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: burst)

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
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: burst)

        #expect(Set(targets.map(\.cursorKey)) == Set(burst))
        #expect(landing(after: burst[0], in: targets, session: session(burst)) == burst[1])
    }

    @Test func alertsKeepsTheRowWhoseAlertWasDismissedMidBurst() {
        let burst = [agentCursor("a"), agentCursor("b")]
        let device = oneDevice(agents: [
            agentRow(id: "a", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:01:00Z"),
            agentRow(id: "b", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:02:00Z"),
        ])

        // The user landed on `a` and dismissed its alert from the pane while the burst is still live.
        let targets = WindowCycleModeTargets.targets(
            mode: .alerts, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [alertID(in: device, workspaceID: "w1", agentID: "a")], recentCursors: [],
            retaining: burst)

        // Both frozen cursors are still candidates, so the burst walks its own order rather than being
        // rebuilt around the one row that is still alerting.
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
            mode: .alerts, devices: devices, openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: burst)

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
            mode: .alerts, devices: devices, openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        // Nothing is being walked, so a working agent is simply not alerting.
        #expect(targets.map(\.cursorKey) == [agentCursor("b")])
    }

    // MARK: - Sidebar visibility

    /// A global mode lists rows the user can be sent to, and a hidden workspace has no sidebar row, so
    /// its alerts stay out however loudly they are asking for an answer, exactly as the Alerts pane
    /// leaves out a hidden workspace's group.
    @Test func alertsSkipsAWaitingAgentInAHiddenWorkspace() {
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
            mode: .alerts, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

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
            openBrowserSessionsByWorkspace: [:], trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

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
            mode: .alerts, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: burst)

        #expect(targets.map(\.cursorKey) == [burst[0]])
    }

    // MARK: - Reachability

    /// A paired device the sidebar can no longer reach keeps its last-known overview (see
    /// `WindowCycleDeviceSnapshot`), so a waiting agent on it is still in the payload and still alerts.
    /// Without an open pane to land on, a cycle press would hit `openOrFocusTerminalPane`'s modal
    /// refusal, so the target, and the row's count, leave it out.
    @Test func anUnreachableDevicesWaitingAgentWithoutAnOpenPaneIsNotATarget() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "linux",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(id: "w1", agents: [agentRow(id: "a-offline", workspaceID: "w1", state: .waiting, updatedAt: "2026-01-01T10:00:00Z")])
                ], sessions: []), isReachable: false)

        let targets = WindowCycleModeTargets.targets(
            mode: .alerts, devices: [device], openTerminalSessionIDsByWorkspace: [:], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

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
            mode: .alerts, devices: [device], openTerminalSessionIDsByWorkspace: ["w1": ["session-a-offline"]], openBrowserSessionsByWorkspace: [:],
            trackedBrowserWindowIDsByWorkspace: [:], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        #expect(targets.map { $0.target.agentWindow?.id } == ["a-offline"])
    }

    /// Open sessions applies the same reachability rule to its browser targets: focusing a browser
    /// session of a remote workspace resolves its SSH-forwarded route through the device record, which
    /// an unreachable device has none of, so the browser target drops while the open pane, which
    /// focuses locally, stays.
    @Test func openSessionsDropsAnUnreachableDevicesBrowserSessionButKeepsItsOpenPane() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "linux",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(
                        id: "w1", browserSessionURL: "http://localhost:3000",
                        terminals: [terminalRow(id: "t-open", workspaceID: "w1", sessionID: "session-open", title: "open")])
                ], sessions: []), isReachable: false)

        let targets = WindowCycleModeTargets.targets(
            mode: .openSessions, devices: [device], openTerminalSessionIDsByWorkspace: ["w1": ["session-open"]],
            openBrowserSessionsByWorkspace: ["w1": [BrowserSession(name: "docs", url: "http://localhost:3000")]],
            trackedBrowserWindowIDsByWorkspace: ["w1": [7]], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        #expect(targets.map(\.cursorKey) == ["device:linux/workspace:w1/terminal:session-open"])
    }

    /// The same fixture with the device reachable keeps both the pane and the browser session.
    @Test func openSessionsKeepsAReachableDevicesBrowserSessionAlongsideItsOpenPane() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "linux",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(
                        id: "w1", browserSessionURL: "http://localhost:3000",
                        terminals: [terminalRow(id: "t-open", workspaceID: "w1", sessionID: "session-open", title: "open")])
                ], sessions: []))

        let targets = WindowCycleModeTargets.targets(
            mode: .openSessions, devices: [device], openTerminalSessionIDsByWorkspace: ["w1": ["session-open"]],
            openBrowserSessionsByWorkspace: ["w1": [BrowserSession(name: "docs", url: "http://localhost:3000")]],
            trackedBrowserWindowIDsByWorkspace: ["w1": [7]], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        #expect(
            targets.map(\.cursorKey) == [
                "device:linux/workspace:w1/browser:http://localhost:3000", "device:linux/workspace:w1/terminal:session-open",
            ])
    }

    /// The local device's own `spacesd` outage reads the section unreachable too, but its browser
    /// sessions focus through this Mac's Chrome with no device record involved, so `isLocal` keeps
    /// them in the set alongside the open pane.
    @Test func openSessionsKeepsTheLocalDevicesBrowserSessionWhileItsOwnDaemonIsDown() {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac",
            overview: SpacesDeviceOverviewPayload(
                workspaces: [
                    workspace(
                        id: "w1", browserSessionURL: "http://localhost:3000",
                        terminals: [terminalRow(id: "t-open", workspaceID: "w1", sessionID: "session-open", title: "open")])
                ], sessions: []), isReachable: false, isLocal: true)

        let targets = WindowCycleModeTargets.targets(
            mode: .openSessions, devices: [device], openTerminalSessionIDsByWorkspace: ["w1": ["session-open"]],
            openBrowserSessionsByWorkspace: ["w1": [BrowserSession(name: "docs", url: "http://localhost:3000")]],
            trackedBrowserWindowIDsByWorkspace: ["w1": [7]], dismissedAlertIDs: [], recentCursors: [], retaining: [])

        #expect(
            targets.map(\.cursorKey) == ["device:mac/workspace:w1/browser:http://localhost:3000", "device:mac/workspace:w1/terminal:session-open"])
    }

    /// `persistedLayoutKeys` is what keeps an unreachable device's persisted-only panes out of the
    /// open-pane map (see the tests above): it should name every workspace of the reachable device and
    /// none of the unreachable one's.
    @Test func persistedLayoutKeysNamesOnlyReachableDevicesWorkspaces() {
        let reachable = WindowCycleDeviceSnapshot(
            deviceID: "mac", overview: SpacesDeviceOverviewPayload(workspaces: [workspace(id: "w1"), workspace(id: "w2")], sessions: []))
        let unreachable = WindowCycleDeviceSnapshot(
            deviceID: "linux", overview: SpacesDeviceOverviewPayload(workspaces: [workspace(id: "w3")], sessions: []), isReachable: false)

        let keys = WindowCycleModeTargets.persistedLayoutKeys(for: [reachable, unreachable])

        #expect(
            keys == [
                PanelLayoutEngine.WorkspaceKey(deviceID: "mac", workspaceID: "w1"),
                PanelLayoutEngine.WorkspaceKey(deviceID: "mac", workspaceID: "w2"),
            ])
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
        processes: [SpacesDeviceWorkspaceProcessRow] = [], agents: [SpacesDeviceWorkspaceCodingAgentRow] = [],
        terminals: [SpacesDeviceWorkspaceTerminalRow] = []
    ) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: projectID, projectName: projectID, branch: id, baseBranch: "main", dir: "/tmp/\(id)", isRunning: true,
            isHidden: isHidden, isDefault: false, hasTrackedRuntimeIndicators: !(processes.isEmpty && agents.isEmpty && terminals.isEmpty),
            config: SpacesDeviceWorkspaceConfig(
                resolvedBrowserSessions: browserSessionURL.map { [SpacesDeviceBrowserSession(name: "docs", url: $0)] } ?? []), processRows: processes,
            codingAgentRows: agents, terminalRows: terminals)
    }

    /// An exited configured process, its session overridable so it can be made to share a session id with
    /// an agent row, the shape a configured process running a coding agent's command takes once that
    /// agent's command exits.
    private func exitedProcessRow(id: String, workspaceID: String, exitedAt: String?, sessionID: String? = nil) -> SpacesDeviceWorkspaceProcessRow {
        SpacesDeviceWorkspaceProcessRow(
            id: "row-\(id)", workspaceID: workspaceID, name: id, command: "npm run dev", templateID: id, processID: id,
            sessionID: sessionID ?? "session-\(id)", runState: .exited, exitedAt: exitedAt, canRun: true, canStop: false, canRestart: true)
    }

    /// A configured process still running, its session overridable so it can be made to share a session
    /// id with an agent row, the shape a configured process running a coding agent's command takes.
    private func runningProcessRow(id: String, workspaceID: String, sessionID: String) -> SpacesDeviceWorkspaceProcessRow {
        SpacesDeviceWorkspaceProcessRow(
            id: "row-\(id)", workspaceID: workspaceID, name: id, command: "claude", templateID: id, processID: id, sessionID: sessionID,
            runState: .running, exitedAt: nil, canRun: false, canStop: true, canRestart: true)
    }

    /// A session summary as the daemon reports one, with the bell stamp a bell alert is derived from.
    private func sessionSummary(id: String, workspaceID: String, bellAt: String? = nil) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: id, workingDirectory: "/tmp/\(workspaceID)", shell: "/bin/zsh", command: nil, state: .running, backend: .ghosttyEmbedded,
            lifetimePolicy: .persistent, servicePID: 100, childPID: nil, workspaceID: workspaceID, workspaceTitle: nil, projectID: nil,
            projectName: nil, createdAt: "2026-01-01T10:00:00Z", updatedAt: "2026-01-01T10:00:00Z", isControlAvailable: true,
            isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .liveSession, bellAt: bellAt)
    }

    /// The pane's own identity for the alert a row carries, read off the same derivation the mode reads,
    /// so a dismissal in a test names what a click would dismiss instead of restating the id format.
    private func alertID(in device: WindowCycleDeviceSnapshot, workspaceID: String, agentID: String) -> String {
        let groups = AlertsController.buildOverviewAlertsGroups(from: device.overview, deviceID: device.deviceID)
        let entries = AlertsController.rowAlertsAttentionEntries(in: groups, workspaceID: workspaceID, agentID: agentID)
        guard let attentionID = entries.first?.attentionID else {
            Issue.record("no alert derived for agent \(agentID)")
            return ""
        }
        return attentionID
    }

    private func agentRow(id: String, workspaceID: String, state: SpacesDeviceCodingAgentActivityState, updatedAt: String?, sessionID: String? = nil)
        -> SpacesDeviceWorkspaceCodingAgentRow
    {
        SpacesDeviceWorkspaceCodingAgentRow(
            id: "row-\(id)", workspaceID: workspaceID, name: id, command: "claude", agentID: id, sessionID: sessionID ?? "session-\(id)",
            runState: .running, activityState: state, updatedAt: updatedAt, canStop: true)
    }

    private func terminalRow(id: String, workspaceID: String, sessionID: String, title: String) -> SpacesDeviceWorkspaceTerminalRow {
        SpacesDeviceWorkspaceTerminalRow(
            id: id, workspaceID: workspaceID, title: title, workingDirectory: "/tmp/\(workspaceID)", sessionID: sessionID, runState: .running,
            canOpenTerminal: true)
    }
}
