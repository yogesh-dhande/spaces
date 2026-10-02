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
struct AlertsControllerBuilderTests {
    private func workspace(
        id: String, projectID: String = "project-1", isRunning: Bool = true, isHidden: Bool = false,
        processRows: [SpacesDeviceWorkspaceProcessRow] = [], codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = []
    ) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: projectID, projectName: "Project", branch: "feature", baseBranch: "main", dir: "/device/\(id)", isRunning: isRunning,
            isHidden: isHidden, isDefault: false, notes: nil, hasTrackedRuntimeIndicators: false, assignedPorts: [], setupState: nil,
            config: SpacesDeviceWorkspaceConfig(), processRows: processRows, codingAgentRows: codingAgentRows, terminalRows: [])
    }

    private func project(id: String, isHidden: Bool = false) -> SpacesDeviceProjectSummary {
        SpacesDeviceProjectSummary(id: id, name: "Project", dir: "/device/\(id)", isGitRepo: true, defaultBranch: "main", isHidden: isHidden)
    }

    private func exitedProcess(id: String, processID: String, exitedAt: String?) -> SpacesDeviceWorkspaceProcessRow {
        SpacesDeviceWorkspaceProcessRow(
            id: id, workspaceID: "ws", name: "web", command: "npm run dev", templateID: id, processID: processID, sessionID: "proc-session", runState: .exited,
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
            activityState: activityState, updatedAt: updatedAt, brief: nil, briefUpdatedAt: nil, canStop: true)
    }

    private func overview(
        _ workspaces: [SpacesDeviceWorkspaceSummary], projects: [SpacesDeviceProjectSummary] = [], sessions: [SpacesDeviceTerminalSessionSummary] = [],
        dismissed: [String] = [], flags: [SpacesDeviceComeBackLaterFlag] = []
    ) -> SpacesDeviceOverviewPayload {
        SpacesDeviceOverviewPayload(
            projects: projects, workspaces: workspaces, sessions: sessions,
            daemonStatus: TerminalServiceDaemonStatus(version: "test", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0),
            dismissedAlertKeys: dismissed, comeBackLaterFlags: flags)
    }

    private func terminalRow(id: String, sessionID: String?, runState: SpacesDeviceRunState = .exited) -> SpacesDeviceWorkspaceTerminalRow {
        SpacesDeviceWorkspaceTerminalRow(
            id: id, workspaceID: "ws", title: "scratch", workingDirectory: "/device/ws", sessionID: sessionID, runState: runState, canOpenTerminal: true,
            liveTitle: "vim")
    }

    private func workspace(id: String, terminalRows: [SpacesDeviceWorkspaceTerminalRow]) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/device/\(id)", isRunning: true,
            isHidden: false, isDefault: false, notes: nil, hasTrackedRuntimeIndicators: false, assignedPorts: [], setupState: nil,
            config: SpacesDeviceWorkspaceConfig(), processRows: [], codingAgentRows: [], terminalRows: terminalRows)
    }

    /// A focus boundary dated the same way the daemon dates a bell, so tests can place a bell either side
    /// of the moment the session took focus.
    private func focusedSince(_ sessionID: String, _ timestamp: String) -> AlertsController.FocusedBellWatch {
        guard let since = GhosttyRemoteSessionStateTimestamp.date(from: timestamp) else {
            Issue.record("unparseable focus timestamp \(timestamp)")
            return AlertsController.FocusedBellWatch(sessionID: sessionID, since: .distantPast)
        }
        return AlertsController.FocusedBellWatch(sessionID: sessionID, since: since)
    }

    private func session(
        id: String, workspaceID: String = "ws", title: String = "shell-1", liveTitle: String? = nil, bellAt: String? = nil,
        state: TerminalSessionState = .running, updatedAt: String = "2026-06-28T09:00:00Z"
    ) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: title, liveTitle: liveTitle, workingDirectory: "/device/ws", shell: "/bin/zsh", command: nil, state: state,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: nil, workspaceID: workspaceID, workspaceTitle: nil,
            projectID: nil, projectName: nil, createdAt: "2026-06-28T09:00:00Z", updatedAt: updatedAt, isControlAvailable: true,
            isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .liveSession, bellAt: bellAt)
    }

    @Test func exitedProcessProducesProcessAlertEvenOnAStoppedWorkspace() {
        let groups = AlertsController.buildOverviewAlertsGroups(
            from: overview([
                workspace(
                    id: "ws", isRunning: false,
                    processRows: [exitedProcess(id: "p1", processID: "run-1", exitedAt: "2026-06-28T10:00:00Z"), runningProcess(id: "p2")])
            ]), deviceID: "local")

        #expect(groups.count == 1)
        #expect(groups[0].items.count == 1)
        let item = groups[0].items[0]
        #expect(item.kind == .processExited)
        #expect(item.processStatus == .exited)
        #expect(item.countsTowardBadge)
        #expect(item.attentionID == "alert:local:process:p1:2026-06-28T10:00:00Z")
        #expect(item.alertKey == "process:p1:2026-06-28T10:00:00Z")
        #expect(item.deviceID == "local")
        if case .workspaceProcess(let wsID, let processID)? = item.focusRequest {
            #expect(wsID == "ws")
            #expect(processID == "run-1")
        } else {
            Issue.record("expected a workspaceProcess focus request")
        }
    }

    @Test func waitingAndDoneAgentsAlertButIdleAndSpinningDoNot() {
        let groups = AlertsController.buildOverviewAlertsGroups(
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

        #expect(groups.count == 1)
        #expect(groups[0].items.count == 2)
        #expect(groups[0].items.allSatisfy { $0.agentStatus == .waiting || $0.agentStatus == .done })
        #expect(groups[0].items.first?.attentionID == "alert:local:agent:a-done:done:2026-06-28T09:30:00Z")

        // A finished agent isn't still blocking on the user, so it must render distinctly from a
        // waiting agent by tint alone (same cpu.fill identity, done blue vs waiting amber).
        let doneItem = groups[0].items.first { $0.agentStatus == .done }
        let waitingItem = groups[0].items.first { $0.agentStatus == .waiting }
        #expect(doneItem?.icon == "cpu.fill")
        #expect(doneItem?.iconTint == .done)
        #expect(waitingItem?.icon == "cpu.fill")
        #expect(waitingItem?.iconTint == .warning)
    }

    @Test func itemsAndGroupsSortByEventDateDescending() {
        let wsA = workspace(
            id: "ws-a",
            processRows: [
                exitedProcess(id: "p-old", processID: "old", exitedAt: "2026-06-28T08:00:00Z"),
                exitedProcess(id: "p-new", processID: "new", exitedAt: "2026-06-28T12:00:00Z"),
            ])
        let wsB = workspace(id: "ws-b", processRows: [exitedProcess(id: "p-mid", processID: "mid", exitedAt: "2026-06-28T10:00:00Z")])

        let groups = AlertsController.buildOverviewAlertsGroups(from: overview([wsB, wsA]), deviceID: "local")

        #expect(groups.map(\.workspaceID) == ["ws-a", "ws-b"])
        #expect(
            groups[0].items.map(\.alertKey) == ["process:p-new:2026-06-28T12:00:00Z", "process:p-old:2026-06-28T08:00:00Z"])
    }

    @Test func workspaceWithoutAttentionItemsProducesNoGroup() {
        let groups = AlertsController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", processRows: [runningProcess(id: "p")])]), deviceID: "local")
        #expect(groups.isEmpty)
    }

    @Test func deviceIDQualifiesTheDeviceFreeKey() {
        let ws = workspace(id: "ws", processRows: [exitedProcess(id: "p", processID: "run-1", exitedAt: "2026-06-28T10:00:00Z")])
        let local = AlertsController.buildOverviewAlertsGroups(from: overview([ws]), deviceID: "local")
        let remote = AlertsController.buildOverviewAlertsGroups(from: overview([ws]), deviceID: "remote-device")
        #expect(local[0].items[0].alertKey == remote[0].items[0].alertKey)
        #expect(local[0].items[0].attentionID == "alert:local:process:p:2026-06-28T10:00:00Z")
        #expect(remote[0].items[0].attentionID == "alert:remote-device:process:p:2026-06-28T10:00:00Z")
        #expect(AlertsController.deviceID(fromAttentionID: remote[0].items[0].attentionID) == "remote-device")
    }

    @Test func sessionWithBellProducesBellAlert() {
        let groups = AlertsController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")]), deviceID: "local")

        #expect(groups.count == 1)
        let item = groups[0].items[0]
        #expect(item.kind == .bell)
        #expect(item.icon == "terminal")
        #expect(item.iconTint == .terminal)
        #expect(item.label == "shell-1")
        #expect(item.detail == nil, "a shell that has reported no title has nothing to say beside its name")
        #expect(item.attentionID == "alert:local:bell:s1:2026-06-28T09:00:00Z")
        if case .terminalSession(let workspaceID, let sessionID)? = item.focusRequest {
            #expect(workspaceID == "ws")
            #expect(sessionID == "s1")
        } else {
            Issue.record("expected a terminalSession focus request")
        }
    }

    /// A bell row reads exactly as the session's sidebar row does: its name, then what its program is
    /// doing. Its presence under Alerts is what says the bell rang.
    @Test func bellAlertRowIsNamedAndDescribedLikeItsSessionRow() {
        let groups = AlertsController.buildOverviewAlertsGroups(
            from: overview(
                [workspace(id: "ws", isRunning: false)],
                sessions: [session(id: "s1", title: "build box", liveTitle: "vim main.swift", bellAt: "2026-06-28T09:00:00Z")]), deviceID: "local")

        #expect(groups[0].items[0].label == "build box")
        #expect(groups[0].items[0].detail == "vim main.swift")
    }

    @Test func aLaterBellInTheSameSessionIsANewAlert() {
        let first = AlertsController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")]), deviceID: "local")
        let later = AlertsController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:05:00Z")]), deviceID: "local")
        #expect(first[0].items[0].attentionID != later[0].items[0].attentionID)
    }

    /// A Linux daemon stamps its runtime state with fractional seconds, so a remote workspace's bell has
    /// to date the row the same way a local one does.
    @Test func bellAlertFromALinuxDaemonIsDated() {
        let groups = AlertsController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00.123Z")]),
            deviceID: "remote-device")
        #expect(groups[0].items[0].eventDate != nil)
    }

    @Test func sessionWithoutBellProducesNoAlert() {
        let groups = AlertsController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: nil)]), deviceID: "local")
        #expect(groups.isEmpty)
    }

    // MARK: - Dismissal comes from the device

    @Test func keysTheDeviceDismissedAreMarkedAndLeaveEveryList() {
        let payload = overview(
            [workspace(id: "ws", processRows: [exitedProcess(id: "p1", processID: "run-1", exitedAt: "2026-06-28T10:00:00Z")])],
            sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")], dismissed: ["bell:s1:2026-06-28T09:00:00Z"])
        let groups = AlertsController.buildOverviewAlertsGroups(from: payload, deviceID: "local")

        #expect(groups[0].items.count == 2, "a dismissed alert stays derived so its row can still read it")
        #expect(groups[0].items.first { $0.kind == .bell }?.isDismissed == true)
        #expect(groups[0].items.first { $0.kind == .processExited }?.isDismissed == false)
        let visible = AlertsController.visibleAlertsGroups(in: groups)
        #expect(visible.flatMap(\.items).map(\.kind) == [.processExited])
    }

    @Test func aDismissedKeyOnOneDeviceDoesNotHideTheSameKeyOnAnother() {
        let workspaces = [workspace(id: "ws", processRows: [exitedProcess(id: "p1", processID: "run-1", exitedAt: "2026-06-28T10:00:00Z")])]
        let dismissedOnA = AlertsController.buildOverviewAlertsGroups(
            from: overview(workspaces, dismissed: ["process:p1:2026-06-28T10:00:00Z"]), deviceID: "device-a")
        let liveOnB = AlertsController.buildOverviewAlertsGroups(from: overview(workspaces), deviceID: "device-b")

        let visible = AlertsController.visibleAlertsGroups(in: dismissedOnA + liveOnB)
        #expect(visible.flatMap(\.items).map(\.attentionID) == ["alert:device-b:process:p1:2026-06-28T10:00:00Z"])
    }

    @Test func aProcessExitReadsAcknowledgedExactlyWhenTheDeviceDismissedIt() {
        let workspaces = [workspace(id: "ws", processRows: [exitedProcess(id: "p1", processID: "run-1", exitedAt: "2026-06-28T10:00:00Z")])]
        let live = AlertsController.buildOverviewAlertsGroups(from: overview(workspaces), deviceID: "local")
        let dismissed = AlertsController.buildOverviewAlertsGroups(from: overview(workspaces, dismissed: ["process:p1:2026-06-28T10:00:00Z"]), deviceID: "local")
        #expect(!AlertsController.isProcessExitAcknowledged(processID: "run-1", workspaceID: "ws", alertsGroups: live))
        #expect(AlertsController.isProcessExitAcknowledged(processID: "run-1", workspaceID: "ws", alertsGroups: dismissed))

        // A later exit carries a new key, so the earlier dismissal no longer applies.
        let exitedAgain = AlertsController.buildOverviewAlertsGroups(
            from: overview(
                [workspace(id: "ws", processRows: [exitedProcess(id: "p1", processID: "run-1", exitedAt: "2026-06-28T11:00:00Z")])], dismissed: ["process:p1:2026-06-28T10:00:00Z"]),
            deviceID: "local")
        #expect(!AlertsController.isProcessExitAcknowledged(processID: "run-1", workspaceID: "ws", alertsGroups: exitedAgain))
    }

    @Test func aMarkOnAProcessDoesNotMakeItsExitReadAcknowledged() {
        let flag = SpacesDeviceComeBackLaterFlag(rowKind: .process, rowID: "p1", flaggedAt: "2026-06-28T11:00:00Z")
        let groups = AlertsController.buildOverviewAlertsGroups(
            from: overview(
                [workspace(id: "ws", processRows: [exitedProcess(id: "p1", processID: "run-1", exitedAt: "2026-06-28T10:00:00Z")])], flags: [flag]), deviceID: "local")
        #expect(groups[0].items.count == 2)
        #expect(!AlertsController.isProcessExitAcknowledged(processID: "run-1", workspaceID: "ws", alertsGroups: groups))
    }

    // MARK: - Ended terminals

    @Test func anExitedTerminalRowAndALooseFailedSessionAlertAndFocusTheirSession() {
        let groups = AlertsController.buildOverviewAlertsGroups(
            from: overview(
                [workspace(id: "ws", terminalRows: [terminalRow(id: "t1", sessionID: "s-row")])],
                sessions: [
                    session(id: "s-row", state: .exited, updatedAt: "2026-06-28T09:00:00Z"),
                    session(id: "s-loose", title: "loose", state: .failed, updatedAt: "2026-06-28T09:10:00Z"),
                ]), deviceID: "local")

        let items = groups[0].items
        #expect(items.map(\.kind) == [.terminalFailed, .terminalExited])
        #expect(items[0].label == "loose")
        #expect(items[1].label == "scratch")
        #expect(items[1].detail == "vim")
        #expect(items.allSatisfy { $0.countsTowardBadge })
        if case .terminalSession(_, let sessionID)? = items[1].focusRequest { #expect(sessionID == "s-row") } else { Issue.record("expected focus") }
        if case .terminalSession(_, let sessionID)? = items[0].focusRequest { #expect(sessionID == "s-loose") } else { Issue.record("expected focus") }
    }

    // MARK: - Come Back Later

    @Test func comeBackLaterMarksAreAlertsNamedAfterTheirRowsAndFocusingTheirTargets() throws {
        let workspaceWithRows = SpacesDeviceWorkspaceSummary(
            id: "ws", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/device/ws", isRunning: true,
            isHidden: false, isDefault: false, notes: nil, hasTrackedRuntimeIndicators: false, assignedPorts: [], setupState: nil,
            config: SpacesDeviceWorkspaceConfig(),
            processRows: [
                SpacesDeviceWorkspaceProcessRow(
                    id: "p1", workspaceID: "ws", name: "web", command: "npm run dev", templateID: "p1", processID: "run-1", sessionID: "s-proc",
                    runState: .running, canRun: false, canStop: true, canRestart: true)
            ], codingAgentRows: [agent(id: "a1", agentID: "ag-1", activityState: .idle, updatedAt: nil)],
            terminalRows: [terminalRow(id: "t1", sessionID: "s-term", runState: .running)])
        let flags = [
            SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "a1", flaggedAt: "2026-06-28T10:00:00Z"),
            SpacesDeviceComeBackLaterFlag(rowKind: .process, rowID: "p1", flaggedAt: "2026-06-28T10:05:00Z"),
            SpacesDeviceComeBackLaterFlag(rowKind: .terminal, rowID: "t1", flaggedAt: "2026-06-28T10:10:00Z"),
        ]
        let groups = AlertsController.buildOverviewAlertsGroups(from: overview([workspaceWithRows], flags: flags), deviceID: "local")

        let items = groups[0].items
        #expect(items.map(\.label) == ["scratch", "web", "Codex"], "newest mark first, each named after its row")
        #expect(items.allSatisfy { $0.kind == .comeBackLater && $0.icon == "bell.badge" && $0.iconTint == .accent && $0.countsTowardBadge })
        #expect(items[0].attentionID == "alert:local:comebacklater:terminal:t1")
        if case .terminalSession(_, let sessionID)? = items[0].focusRequest { #expect(sessionID == "s-term") } else { Issue.record("expected focus") }
        if case .workspaceProcess(_, let processID)? = items[1].focusRequest { #expect(processID == "run-1") } else { Issue.record("expected focus") }
        if case .agentWindow(let record)? = items[2].focusRequest { #expect(record.id == "ag-1") } else { Issue.record("expected focus") }
    }

    @Test func aMarkSurvivesTheRowsOwnAlertsAndIsOwnedByTheRow() {
        let flag = SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "a-done", flaggedAt: "2026-06-28T11:00:00Z")
        let groups = AlertsController.buildOverviewAlertsGroups(
            from: overview(
                [workspace(id: "ws", codingAgentRows: [agent(id: "a-done", agentID: "ag-2", activityState: .done, updatedAt: "2026-06-28T09:30:00Z")])],
                flags: [flag]), deviceID: "local")

        let owned = AlertsController.rowAlertsAttentionEntries(in: groups, workspaceID: "ws", agentID: "ag-2")
        #expect(Set(owned.map(\.kind)) == [.agentDone, .comeBackLater])
    }

    @Test func aHiddenWorkspacesMarkIsDerivedButNotListed() {
        let flag = SpacesDeviceComeBackLaterFlag(rowKind: .agent, rowID: "a1", flaggedAt: "2026-06-28T11:00:00Z")
        let groups = AlertsController.buildOverviewAlertsGroups(
            from: overview(
                [workspace(id: "ws", isHidden: true, codingAgentRows: [agent(id: "a1", agentID: "ag-1", activityState: .idle, updatedAt: nil)])],
                projects: [project(id: "project-1")], flags: [flag]), deviceID: "local")
        #expect(groups.count == 1)
        #expect(AlertsController.visibleAlertsGroups(in: groups).isEmpty)
    }

    // MARK: - Hidden workspaces

    @Test func groupsCarryWhetherTheirWorkspaceIsHidden() {
        let groups = AlertsController.buildOverviewAlertsGroups(
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

    @Test func hiddenWorkspaceGroupsAreNeitherShownNorCounted() {
        let groups = AlertsController.buildOverviewAlertsGroups(
            from: overview(
                [workspace(id: "ws-visible", isRunning: false), workspace(id: "ws-hidden", isRunning: false, isHidden: true)],
                projects: [project(id: "project-1")],
                sessions: [
                    session(id: "s1", workspaceID: "ws-visible", bellAt: "2026-06-28T09:00:00Z"),
                    session(id: "s2", workspaceID: "ws-hidden", bellAt: "2026-06-28T09:00:00Z"),
                ]), deviceID: "local")

        let visible = AlertsController.visibleAlertsGroups(in: groups)
        #expect(visible.count == 1)
        #expect(visible.first?.workspaceID == "ws-visible")
        #expect(visible.reduce(0) { $0 + $1.items.filter(\.countsTowardBadge).count } == 1)
    }

    // MARK: - Watched bells

    /// The bell of the session the user is typing in is taken for dismissal: only the focused session's
    /// undismissed bell, and nothing else that happens to focus the same session.
    @Test func onlyTheFocusedSessionsUndismissedBellIsConsumed() {
        let payload = overview(
            [workspace(id: "ws", isRunning: false)],
            sessions: [
                session(id: "s1", title: "focused", bellAt: "2026-06-28T09:00:00Z"),
                session(id: "s2", title: "background", bellAt: "2026-06-28T09:00:01Z"),
                session(id: "s3", title: "ended", state: .exited, updatedAt: "2026-06-28T09:00:02Z"),
            ])
        let groups = AlertsController.buildOverviewAlertsGroups(from: payload, deviceID: "local")
        #expect(AlertsController.bellAttentionIDs(in: groups, watch: focusedSince("s1", "2026-06-28T08:59:00Z")) == ["alert:local:bell:s1:2026-06-28T09:00:00Z"])
        #expect(AlertsController.bellAttentionIDs(in: groups, watch: focusedSince("s3", "2026-06-28T08:59:00Z")).isEmpty)

        let alreadyDismissed = AlertsController.buildOverviewAlertsGroups(
            from: overview(
                [workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")],
                dismissed: ["bell:s1:2026-06-28T09:00:00Z"]), deviceID: "local")
        #expect(AlertsController.bellAttentionIDs(in: alreadyDismissed, watch: focusedSince("s1", "2026-06-28T08:59:00Z")).isEmpty)
    }

    /// Focusing a session is not a way to clear its alerts: a bell rung before focus arrived survives.
    @Test func aBellRungBeforeFocusArrivedIsNotConsumed() {
        let payload = overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: "2026-06-28T09:00:00Z")])
        let groups = AlertsController.buildOverviewAlertsGroups(from: payload, deviceID: "local")
        #expect(AlertsController.bellAttentionIDs(in: groups, watch: focusedSince("s1", "2026-06-28T09:10:00Z")).isEmpty)
        #expect(AlertsController.visibleAlertsGroups(in: groups).flatMap(\.items).count == 1)
    }

    /// `bellAt` comes from the daemon's clock and the focus time from this Mac's, so the boundary carries
    /// a little skew tolerance.
    @Test func aBellRungAfterFocusArrivedIsConsumedIncludingJustInsideTheSkewTolerance() {
        let watch = focusedSince("s1", "2026-06-28T09:00:00Z")
        func consumed(bellAt: String) -> Int {
            let groups = AlertsController.buildOverviewAlertsGroups(
                from: overview([workspace(id: "ws", isRunning: false)], sessions: [session(id: "s1", bellAt: bellAt)]), deviceID: "local")
            return AlertsController.bellAttentionIDs(in: groups, watch: watch).count
        }
        #expect(consumed(bellAt: "2026-06-28T09:00:05Z") == 1)
        #expect(consumed(bellAt: "2026-06-28T08:59:59Z") == 1)
        #expect(consumed(bellAt: "2026-06-28T08:59:00Z") == 0)
    }

    /// Every arrival at a session starts its own boundary, and leaving every pane clears it.
    @Test func theFocusBoundaryRestartsOnEachArrivalAndClearsWhenNothingIsFocused() {
        let firstArrival = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let watch = AlertsController.updatedFocusedBellWatch(nil, focusedSessionID: "s1", now: firstArrival)
        #expect(watch == AlertsController.FocusedBellWatch(sessionID: "s1", since: firstArrival))

        let unchanged = AlertsController.updatedFocusedBellWatch(watch, focusedSessionID: "s1", now: firstArrival.addingTimeInterval(60))
        #expect(unchanged == watch)

        #expect(AlertsController.updatedFocusedBellWatch(watch, focusedSessionID: nil, now: firstArrival.addingTimeInterval(120)) == nil)

        let secondArrival = firstArrival.addingTimeInterval(180)
        let returned = AlertsController.updatedFocusedBellWatch(nil, focusedSessionID: "s1", now: secondArrival)
        #expect(returned == AlertsController.FocusedBellWatch(sessionID: "s1", since: secondArrival))
    }
}
