import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacesui

/// Covers the overview-based attention-alerts builder that supersedes the orchestrator-backed
/// local builder, so local alerts are produced from the Device API overview (no `spaces.db` read)
/// identically to remote alerts.
struct AppKitControllerAlertsBuilderTests {
    private func workspace(
        id: String, projectID: String = "project-1", isRunning: Bool = true, isHidden: Bool = false,
        processRows: [SpacesDeviceWorkspaceProcessRow] = [], codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = []
    ) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: projectID, projectName: "Project", branch: "feature", baseBranch: "main", dir: "/device/\(id)", isRunning: isRunning,
            isHidden: isHidden, isDefault: false, notes: nil, sessionCount: 0, assignedPorts: [], setupState: nil,
            config: SpacesDeviceWorkspaceConfig(), processRows: processRows, codingAgentRows: codingAgentRows, terminalRows: [])
    }

    private func project(id: String, isHidden: Bool = false) -> SpacesDeviceProjectSummary {
        SpacesDeviceProjectSummary(id: id, name: "Project", dir: "/device/\(id)", isGitRepo: true, defaultBranch: "main", isHidden: isHidden)
    }

    private func exitedProcess(id: String, processID: String, exitedAt: String?) -> SpacesDeviceWorkspaceProcessRow {
        SpacesDeviceWorkspaceProcessRow(
            id: id, workspaceID: "ws", name: "web", command: "npm run dev", templateID: id, processID: processID, sessionID: nil, runState: .exited,
            exitedAt: exitedAt, canRun: true, canStop: false, canRestart: true)
    }

    private func runningProcess(id: String) -> SpacesDeviceWorkspaceProcessRow {
        SpacesDeviceWorkspaceProcessRow(
            id: id, workspaceID: "ws", name: "api", command: "npm run api", templateID: id, processID: "run-\(id)", sessionID: nil,
            runState: .running, canRun: false, canStop: true, canRestart: true)
    }

    private func agent(id: String, agentID: String?, activityState: SpacesDeviceCodingAgentActivityState, updatedAt: String?)
        -> SpacesDeviceWorkspaceCodingAgentRow
    {
        SpacesDeviceWorkspaceCodingAgentRow(
            id: id, workspaceID: "ws", name: "Codex", command: "codex", agentID: agentID, sessionID: nil, runState: .running,
            activityState: activityState, updatedAt: updatedAt, canStop: true)
    }

    private func overview(
        _ workspaces: [SpacesDeviceWorkspaceSummary], projects: [SpacesDeviceProjectSummary] = [], sessions: [SpacesDeviceTerminalSessionSummary] = []
    ) -> SpacesDeviceOverviewPayload { SpacesDeviceOverviewPayload(projects: projects, workspaces: workspaces, sessions: sessions) }

    /// A focus boundary dated the same way the daemon dates a bell, so tests can place a bell either side
    /// of the moment the session took focus.
    private func focusedSince(_ sessionID: String, _ timestamp: String) -> AlertsController.FocusedBellWatch {
        guard let since = GhosttyRemoteSessionStateTimestamp.date(from: timestamp) else {
            Issue.record("unparseable focus timestamp \(timestamp)")
            return AlertsController.FocusedBellWatch(sessionID: sessionID, since: .distantPast)
        }
        return AlertsController.FocusedBellWatch(sessionID: sessionID, since: since)
    }

    private func session(id: String, workspaceID: String = "ws", title: String = "shell-1", liveTitle: String? = nil, bellAt: String? = nil)
        -> SpacesDeviceTerminalSessionSummary
    {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: title, liveTitle: liveTitle, workingDirectory: "/device/ws", shell: "/bin/zsh", command: nil, state: .running,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: nil, workspaceID: workspaceID, workspaceTitle: nil,
            projectID: nil, projectName: nil, createdAt: "2026-06-28T09:00:00Z", updatedAt: "2026-06-28T09:00:00Z", isControlAvailable: true,
            isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .liveSession, bellAt: bellAt)
    }

    @Test func exitedProcessOnRunningWorkspaceProducesProcessAlert() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview([
                workspace(
                    id: "ws", processRows: [exitedProcess(id: "p1", processID: "run-1", exitedAt: "2026-06-28T10:00:00Z"), runningProcess(id: "p2")])
            ]), deviceID: "local")

        #expect(groups.count == 1)
        #expect(groups[0].items.count == 1)
        let item = groups[0].items[0]
        #expect(item.processStatus == .exited)
        #expect(item.countsTowardBadge)
        #expect(item.attentionID == "alert:local:process:run-1:2026-06-28T10:00:00Z")
        if case .workspaceProcess(let wsID, let processID)? = item.focusRequest {
            #expect(wsID == "ws")
            #expect(processID == "run-1")
        } else {
            Issue.record("expected a workspaceProcess focus request")
        }
    }

    @Test func waitingAndDoneAgentsAlertButIdleAndSpinningDoNot() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview([
                workspace(
                    id: "ws", isRunning: false,
                    codingAgentRows: [
                        agent(id: "a-wait", agentID: "ag-1", activityState: .waiting, updatedAt: "2026-06-28T09:00:00Z"),
                        agent(id: "a-done", agentID: "ag-2", activityState: .done, updatedAt: "2026-06-28T09:30:00Z"),
                        agent(id: "a-idle", agentID: "ag-3", activityState: .idle, updatedAt: nil),
                        agent(id: "a-spin", agentID: "ag-4", activityState: .spinning, updatedAt: nil),
                    ])
            ]), deviceID: "local")

        // Agents draw attention even on a stopped workspace; idle/spinning never do.
        #expect(groups.count == 1)
        #expect(groups[0].items.count == 2)
        #expect(groups[0].items.allSatisfy { $0.agentStatus == .waiting || $0.agentStatus == .done })
        #expect(groups[0].items.first?.attentionID == "alert:local:agent:ag-2:done:2026-06-28T09:30:00Z")

        // A finished agent isn't still blocking on the user, so it must render distinctly from a
        // waiting agent by tint alone (same cpu.fill identity, done blue vs waiting amber).
        let doneItem = groups[0].items.first { $0.agentStatus == .done }
        let waitingItem = groups[0].items.first { $0.agentStatus == .waiting }
        #expect(doneItem?.icon == "cpu.fill")
        #expect(doneItem?.iconTint == .done)
        #expect(waitingItem?.icon == "cpu.fill")
        #expect(waitingItem?.iconTint == .warning)
        #expect(doneItem?.iconTint != waitingItem?.iconTint)
    }

    @Test func exitedProcessOnStoppedWorkspaceIsIgnored() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false, processRows: [exitedProcess(id: "p1", processID: "run-1", exitedAt: "t")])]),
            deviceID: "local")
        #expect(groups.isEmpty)
    }

    @Test func itemsAndGroupsSortByEventDateDescending() {
        let wsA = workspace(
            id: "ws-a",
            processRows: [
                exitedProcess(id: "p-old", processID: "old", exitedAt: "2026-06-28T08:00:00Z"),
                exitedProcess(id: "p-new", processID: "new", exitedAt: "2026-06-28T12:00:00Z"),
            ])
        let wsB = workspace(id: "ws-b", processRows: [exitedProcess(id: "p-mid", processID: "mid", exitedAt: "2026-06-28T10:00:00Z")])

        let groups = AppKitController.buildOverviewAlertsGroups(from: overview([wsB, wsA]), deviceID: "local")

        // Group whose most-recent alert is newest comes first; within a group, newest exit first.
        #expect(groups.map(\.workspaceID) == ["ws-a", "ws-b"])
        #expect(
            groups[0].items.map(\.attentionID) == ["alert:local:process:new:2026-06-28T12:00:00Z", "alert:local:process:old:2026-06-28T08:00:00Z"])
    }

    @Test func workspaceWithoutAttentionItemsProducesNoGroup() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", processRows: [runningProcess(id: "p")])]), deviceID: "local")
        #expect(groups.isEmpty)
    }

    @Test func deviceIDScopesAttentionIDsAcrossDevices() {
        let ws = workspace(id: "ws", processRows: [exitedProcess(id: "p", processID: "run-1", exitedAt: "t")])
        let local = AppKitController.buildOverviewAlertsGroups(from: overview([ws]), deviceID: "local")
        let remote = AppKitController.buildOverviewAlertsGroups(from: overview([ws]), deviceID: "remote-device")
        #expect(local[0].items[0].attentionID == "alert:local:process:run-1:t")
        #expect(remote[0].items[0].attentionID == "alert:remote-device:process:run-1:t")
    }

    @Test func sessionWithBellProducesBellAlert() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")]), deviceID: "local")

        #expect(groups.count == 1)
        #expect(groups[0].items.count == 1)
        let item = groups[0].items[0]
        #expect(item.icon == "terminal")
        #expect(item.iconTint == .terminal)
        #expect(item.label == "shell-1")
        #expect(item.detail == nil, "a shell that has reported no title has nothing to say beside its name")
        #expect(item.attentionID == "alert:local:session:s1:bell:2026-06-28T09:00:00Z")
        if case .terminalSession(let workspaceID, let sessionID)? = item.focusRequest {
            #expect(workspaceID == "ws")
            #expect(sessionID == "s1")
        } else {
            Issue.record("expected a terminalSession focus request")
        }
    }

    /// A bell row reads exactly as the session's sidebar row does — its name, then what its program is
    /// doing. Its presence under Alerts is what says the bell rang, so it never spends the row on
    /// saying so.
    @Test func bellAlertRowIsNamedAndDescribedLikeItsSessionRow() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview(
                [workspace(id: "ws", isRunning: false)],
                sessions: [session(id: "s1", title: "build box", liveTitle: "vim main.swift", bellAt: "2026-06-28T09:00:00Z")]), deviceID: "local")

        #expect(groups[0].items[0].label == "build box")
        #expect(groups[0].items[0].detail == "vim main.swift")
    }

    @Test func bellAlertIdentityIsStableAcrossBuildsAndChangesWithBellAt() {
        let firstBuild = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")]), deviceID: "local")
        let secondBuild = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")]), deviceID: "local")
        #expect(firstBuild[0].items[0].attentionID == secondBuild[0].items[0].attentionID)

        let laterBell = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:05:00Z")]), deviceID: "local")
        #expect(laterBell[0].items[0].attentionID != firstBuild[0].items[0].attentionID)
    }

    /// A Linux daemon stamps its runtime state with fractional seconds, so a remote workspace's bell has
    /// to date the row the same way a local one does — the age is the only recency a bell row carries.
    @Test func bellAlertFromALinuxDaemonIsDated() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00.123Z")]),
            deviceID: "remote-device")
        #expect(groups[0].items[0].eventDate != nil)
    }

    /// The bell of the session the user is typing in is consumed, not filtered: only the focused
    /// session's identity is taken, and the alert disappears from what the user sees.
    @Test func focusedSessionsBellIsConsumedAndOtherSessionsStillAlert() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview(
                [workspace(id: "ws", isRunning: false)],
                sessions: [
                    session(id: "s1", title: "focused", bellAt: "2026-06-28T09:00:00Z"),
                    session(id: "s2", title: "background", bellAt: "2026-06-28T09:00:01Z"),
                ]), deviceID: "local")

        let consumed = AlertsController.bellAttentionIDs(in: groups, watch: focusedSince("s1", "2026-06-28T08:59:00Z"))

        #expect(consumed == ["alert:local:session:s1:bell:2026-06-28T09:00:00Z"])
        let visible = AlertsController.visibleAlertsGroups(in: groups, dismissedAttentionItemIDs: consumed)
        #expect(visible.flatMap(\.items).map(\.label) == ["background"])
    }

    /// A consumed bell must stay consumed once the user moves focus to another pane — the daemon keeps
    /// reporting the same `bellAt`, so a suppression that only held while the session was focused would
    /// raise the alert the moment focus moved. The identity is what survives, and a later bell in the
    /// same session carries a new one and alerts.
    @Test func consumedBellStaysGoneAfterFocusMovesAndALaterBellAlerts() {
        let workspaces = [workspace(id: "ws", isRunning: false)]
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview(workspaces, sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")]), deviceID: "local")
        let dismissed = AlertsController.bellAttentionIDs(in: groups, watch: focusedSince("s1", "2026-06-28T08:59:00Z"))

        // Focus has moved elsewhere: the same overview is rebuilt with nothing focused.
        let afterFocusMoved = AppKitController.buildOverviewAlertsGroups(
            from: overview(workspaces, sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")]), deviceID: "local")
        #expect(AlertsController.visibleAlertsGroups(in: afterFocusMoved, dismissedAttentionItemIDs: dismissed).isEmpty)

        let laterBell = AppKitController.buildOverviewAlertsGroups(
            from: overview(workspaces, sessions: [session(id: "s1", bellAt: "2026-06-28T09:05:00Z")]), deviceID: "local")
        #expect(AlertsController.visibleAlertsGroups(in: laterBell, dismissedAttentionItemIDs: dismissed).flatMap(\.items).count == 1)
    }

    /// Consumption is only durable if the pruning pass keeps it: dismissals are trimmed to the alerts
    /// currently derived, and a consumed bell is still derived (that is why the builder emits it for the
    /// focused session too). Once its `bellAt` is superseded, the stale identity is dropped.
    @Test func consumedBellIdentitySurvivesPruningUntilItsBellAtIsSuperseded() {
        let workspaces = [workspace(id: "ws", isRunning: false)]
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview(workspaces, sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")]), deviceID: "local")
        let dismissed = AlertsController.bellAttentionIDs(in: groups, watch: focusedSince("s1", "2026-06-28T08:59:00Z"))

        #expect(AlertsController.retainedDismissedAttentionItemIDs(dismissed, in: groups) == dismissed)

        let laterBell = AppKitController.buildOverviewAlertsGroups(
            from: overview(workspaces, sessions: [session(id: "s1", bellAt: "2026-06-28T09:05:00Z")]), deviceID: "local")
        #expect(AlertsController.retainedDismissedAttentionItemIDs(dismissed, in: laterBell).isEmpty)
    }

    /// Focusing a session is not a way to clear its alerts. A bell it rang while the user was elsewhere is
    /// a legitimate alert, and it survives every rebuild that happens while the session holds focus —
    /// only the user dismissing it takes it away.
    @Test func aBellRungBeforeFocusArrivedSurvivesRebuildsWhileFocused() {
        let payload = overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")])
        let watch = focusedSince("s1", "2026-06-28T09:10:00Z")

        for _ in 0..<2 {
            let groups = AppKitController.buildOverviewAlertsGroups(from: payload, deviceID: "local")
            #expect(AlertsController.bellAttentionIDs(in: groups, watch: watch).isEmpty)
            #expect(AlertsController.visibleAlertsGroups(in: groups, dismissedAttentionItemIDs: []).flatMap(\.items).count == 1)
        }
    }

    /// The bell rung after the user arrived is the one happening in front of them, and it is consumed even
    /// though the same session's earlier bell was not. The boundary carries a little skew tolerance
    /// because `bellAt` comes from the daemon's clock and the focus time from this Mac's.
    @Test func aBellRungAfterFocusArrivedIsConsumedIncludingJustInsideTheSkewTolerance() {
        let watch = focusedSince("s1", "2026-06-28T09:00:00Z")

        let afterFocus = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:05Z")]), deviceID: "local")
        #expect(AlertsController.bellAttentionIDs(in: afterFocus, watch: watch).count == 1)

        let justBeforeFocus = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T08:59:59Z")]), deviceID: "local")
        #expect(AlertsController.bellAttentionIDs(in: justBeforeFocus, watch: watch).count == 1)

        let wellBeforeFocus = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T08:59:00Z")]), deviceID: "local")
        #expect(AlertsController.bellAttentionIDs(in: wellBeforeFocus, watch: watch).isEmpty)
    }

    /// Every arrival at a session starts its own boundary, and leaving every pane clears it — otherwise a
    /// session focused hours ago would keep consuming bells rung long after the user walked away.
    @Test func theFocusBoundaryRestartsOnEachArrivalAndClearsWhenNothingIsFocused() {
        let firstArrival = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let watch = AlertsController.updatedFocusedBellWatch(nil, focusedSessionID: "s1", now: firstArrival)
        #expect(watch == AlertsController.FocusedBellWatch(sessionID: "s1", since: firstArrival))

        // A rebuild that sees the same session focused keeps the original arrival time.
        let unchanged = AlertsController.updatedFocusedBellWatch(watch, focusedSessionID: "s1", now: firstArrival.addingTimeInterval(60))
        #expect(unchanged == watch)

        #expect(AlertsController.updatedFocusedBellWatch(watch, focusedSessionID: nil, now: firstArrival.addingTimeInterval(120)) == nil)

        let secondArrival = firstArrival.addingTimeInterval(180)
        let returned = AlertsController.updatedFocusedBellWatch(nil, focusedSessionID: "s1", now: secondArrival)
        #expect(returned == AlertsController.FocusedBellWatch(sessionID: "s1", since: secondArrival))
    }

    /// Focus leaving and coming back must not resurrect what was already consumed: the identity stays in
    /// the dismissed set, and the fresh boundary only governs which *new* bells get consumed.
    @Test func focusReturningDoesNotResurrectAConsumedBell() {
        let payload = overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")])
        let groups = AppKitController.buildOverviewAlertsGroups(from: payload, deviceID: "local")
        let dismissed = AlertsController.bellAttentionIDs(in: groups, watch: focusedSince("s1", "2026-06-28T08:59:00Z"))
        #expect(!dismissed.isEmpty)

        // Focus left and came back later, so the boundary is now after that bell — it is not re-consumed,
        // and it is not shown either, because consuming it once was a dismissal.
        let afterReturning = AppKitController.buildOverviewAlertsGroups(from: payload, deviceID: "local")
        #expect(AlertsController.bellAttentionIDs(in: afterReturning, watch: focusedSince("s1", "2026-06-28T09:30:00Z")).isEmpty)
        #expect(AlertsController.visibleAlertsGroups(in: afterReturning, dismissedAttentionItemIDs: dismissed).isEmpty)
    }

    @Test func sessionWithoutBellProducesNoAlert() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: nil)]), deviceID: "local")
        #expect(groups.isEmpty)
    }

    /// Hiding a workspace, or hiding its project, tags the group rather than dropping it: the group has to
    /// stay derived for its dismissal identities to survive the hide (see
    /// `dismissedAlertsFromAHiddenWorkspaceAreRetained`), and the display surfaces read the tag.
    @Test func groupsCarryWhetherTheirWorkspaceIsHidden() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview(
                [
                    workspace(id: "ws-visible", isRunning: false), workspace(id: "ws-hidden", isRunning: false, isHidden: true),
                    workspace(id: "ws-hidden-project", projectID: "project-hidden", isRunning: false),
                ], projects: [project(id: "project-1"), project(id: "project-hidden", isHidden: true)],
                sessions: [
                    session(id: "s1", workspaceID: "ws-visible", bellAt: "2026-06-28T09:00:00Z"),
                    session(id: "s2", workspaceID: "ws-hidden", bellAt: "2026-06-28T09:00:00Z"),
                    session(id: "s3", workspaceID: "ws-hidden-project", bellAt: "2026-06-28T09:00:00Z"),
                ]), deviceID: "local")

        #expect(groups.count == 3)
        #expect(groups.first { $0.workspaceID == "ws-visible" }?.isFromHiddenWorkspace == false)
        #expect(groups.first { $0.workspaceID == "ws-hidden" }?.isFromHiddenWorkspace == true)
        #expect(groups.first { $0.workspaceID == "ws-hidden-project" }?.isFromHiddenWorkspace == true)
    }

    /// The pane and the badge both derive from `visibleAlertsGroups`, so tagging is what keeps a hidden
    /// workspace's alerts off screen and out of the count.
    @Test func hiddenWorkspaceGroupsAreNeitherShownNorCounted() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview(
                [workspace(id: "ws-visible", isRunning: false), workspace(id: "ws-hidden", isRunning: false, isHidden: true)],
                projects: [project(id: "project-1")],
                sessions: [
                    session(id: "s1", workspaceID: "ws-visible", bellAt: "2026-06-28T09:00:00Z"),
                    session(id: "s2", workspaceID: "ws-hidden", bellAt: "2026-06-28T09:00:00Z"),
                ]), deviceID: "local")

        let visible = AlertsController.visibleAlertsGroups(in: groups, dismissedAttentionItemIDs: [])
        #expect(visible.count == 1)
        #expect(visible.first?.workspaceID == "ws-visible")
        // The badge is this reduction over the same groups (`alertsAttentionCount`).
        #expect(visible.reduce(0) { $0 + $1.items.filter(\.countsTowardBadge).count } == 1)
    }

    /// Dismissals of a hidden workspace's alerts are retained, so unhiding the workspace does not bring
    /// back alerts the user already cleared.
    @Test func dismissedAlertsFromAHiddenWorkspaceAreRetained() {
        let payload = overview(
            [workspace(id: "ws-hidden", isRunning: false, isHidden: true)], projects: [project(id: "project-1")],
            sessions: [session(id: "s1", workspaceID: "ws-hidden", bellAt: "2026-06-28T09:00:00Z")])
        let groups = AppKitController.buildOverviewAlertsGroups(from: payload, deviceID: "local")
        let dismissed = Set(groups.flatMap { $0.items.map(\.attentionID) })
        #expect(dismissed.count == 1)

        #expect(AlertsController.retainedDismissedAttentionItemIDs(dismissed, in: groups) == dismissed)
        #expect(AlertsController.visibleAlertsGroups(in: groups, dismissedAttentionItemIDs: dismissed).isEmpty)
    }
}
