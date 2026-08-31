import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacesui

/// Covers the shared derivation both overview apply sites (`applyDeviceOverview`,
/// `applyRemoteDeviceSection`) compose from: projects, workspaces, runtime status, and alerts
/// groups produced from a single overview payload should never disagree with one another.
struct DeviceSectionContentTests {
    private func workspace(
        id: String, projectID: String = "project-1", isRunning: Bool = true, isHidden: Bool = false,
        processRows: [SpacesDeviceWorkspaceProcessRow] = []
    ) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: projectID, projectName: "Project", branch: "feature", baseBranch: "main", dir: "/device/\(id)", isRunning: isRunning,
            isHidden: isHidden, isDefault: false, notes: nil, sessionCount: 0, assignedPorts: [], setupState: nil,
            config: SpacesDeviceWorkspaceConfig(), processRows: processRows, terminalRows: [])
    }

    private func project(id: String, isHidden: Bool = false) -> SpacesDeviceProjectSummary {
        SpacesDeviceProjectSummary(id: id, name: "Project \(id)", dir: "/device/\(id)", isGitRepo: true, defaultBranch: "main", isHidden: isHidden)
    }

    private func exitedProcess(id: String, processID: String, exitedAt: String) -> SpacesDeviceWorkspaceProcessRow {
        SpacesDeviceWorkspaceProcessRow(
            id: id, workspaceID: "ws-running", name: "web", command: "npm run dev", templateID: id, processID: processID, sessionID: nil,
            runState: .exited, exitedAt: exitedAt, canRun: true, canStop: false, canRestart: true)
    }

    private func session(id: String, workspaceID: String, title: String, bellAt: String?) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: title, liveTitle: nil, workingDirectory: "/device/\(workspaceID)", shell: "/bin/zsh", command: nil, state: .running,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: nil, workspaceID: workspaceID, workspaceTitle: nil,
            projectID: nil, projectName: nil, createdAt: "2026-06-28T09:00:00Z", updatedAt: "2026-06-28T09:00:00Z", isControlAvailable: true,
            isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .liveSession, bellAt: bellAt)
    }

    private func failedAutomationRun() -> TerminalServiceAutomationRunSummary {
        TerminalServiceAutomationRunSummary(
            id: "run-1", automationID: "auto-1", automationName: "nightly", kind: "script", status: "failed", trigger: "schedule", skipReason: nil,
            exitCode: 1, terminalSessionID: nil, startedAt: "2026-06-28T09:00:00Z", endedAt: "2026-06-28T09:01:00Z",
            createdAt: "2026-06-28T09:00:00Z")
    }

    /// One fixture shared by every test: two projects, a hidden workspace, a running workspace with an
    /// exited process, a session with a bell, and a failed automation run (whose synthetic alerts group is
    /// the one place `deviceName` surfaces). `extraSessions` lets one test add a bell on the hidden
    /// workspace without duplicating the rest of the fixture.
    private func fixtureOverview(extraSessions: [SpacesDeviceTerminalSessionSummary] = []) -> SpacesDeviceOverviewPayload {
        SpacesDeviceOverviewPayload(
            projects: [project(id: "project-1"), project(id: "project-2")],
            workspaces: [
                workspace(id: "ws-running", processRows: [exitedProcess(id: "p1", processID: "run-1", exitedAt: "2026-06-28T10:00:00Z")]),
                workspace(id: "ws-hidden", projectID: "project-2", isRunning: false, isHidden: true),
            ],
            sessions: [session(id: "s1", workspaceID: "ws-running", title: "shell-1", bellAt: "2026-06-28T09:00:00Z")] + extraSessions,
            daemonStatus: .testStatus, automationRuns: [failedAutomationRun()])
    }

    @Test func projectsCarryTheCollapseStateFromThePassedMap() {
        let content = DeviceSectionContent.derive(
            from: fixtureOverview(), deviceID: "local", deviceName: "Local", projectCollapseStates: ["project-1": true])

        #expect(content.projects.map(\.id).sorted() == ["project-1", "project-2"])
        #expect(content.projects.first { $0.id == "project-1" }?.isCollapsed == true)
        #expect(content.projects.first { $0.id == "project-2" }?.isCollapsed == false)
    }

    @Test func workspacesGroupUnderTheirProjectAndCarryTheDeviceID() {
        let content = DeviceSectionContent.derive(from: fixtureOverview(), deviceID: "local", deviceName: "Local", projectCollapseStates: [:])

        #expect(content.workspacesByProject["project-1"]?.map(\.id) == ["ws-running"])
        #expect(content.workspacesByProject["project-2"]?.map(\.id) == ["ws-hidden"])
        #expect(content.workspacesByProject["project-1"]?.first?.deviceID == "local")
    }

    @Test func runningWorkspaceCarriesItsExitedProcessInRuntimeStatus() {
        let content = DeviceSectionContent.derive(from: fixtureOverview(), deviceID: "local", deviceName: "Local", projectCollapseStates: [:])

        let runtime = content.workspaceRuntimeStatusByID["ws-running"]
        #expect(runtime?.lifecycleState == .running)
        #expect(runtime?.exitedProcessCount == 1)
        #expect(content.workspaceRuntimeStatusByID["ws-hidden"]?.lifecycleState == .stopped)
    }

    @Test func alertsGroupsCarryTheExitedProcessAndTheBell() {
        let content = DeviceSectionContent.derive(from: fixtureOverview(), deviceID: "local", deviceName: "Bench Mac", projectCollapseStates: [:])

        let processAlert = content.alertsGroups.first { $0.workspaceID == "ws-running" }
        #expect(processAlert?.items.contains { $0.processStatus == .exited } == true)
        #expect(processAlert?.items.contains { $0.label == "shell-1" } == true)
        #expect(processAlert?.isFromHiddenWorkspace == false)
    }

    /// `deviceName` only surfaces through the synthetic "Automations" group's workspace name, so that
    /// group is the one place propagation can be observed end to end.
    @Test func alertsGroupsNameTheDeviceOnTheAutomationsGroup() {
        let content = DeviceSectionContent.derive(from: fixtureOverview(), deviceID: "local", deviceName: "Bench Mac", projectCollapseStates: [:])

        let automationsGroup = content.alertsGroups.first { $0.projectName == "Automations" }
        #expect(automationsGroup?.workspaceName == "Bench Mac")
    }

    @Test func hiddenWorkspaceAlertsGroupIsFlagged() {
        // The hidden workspace has no bell/exit of its own in the base fixture; add one via a variant
        // overview so its group actually derives and can be checked for the hidden flag.
        let overview = fixtureOverview(
            extraSessions: [session(id: "s2", workspaceID: "ws-hidden", title: "hidden-shell", bellAt: "2026-06-28T09:05:00Z")])
        let withHiddenAlert = DeviceSectionContent.derive(from: overview, deviceID: "local", deviceName: "Local", projectCollapseStates: [:])

        let hiddenGroup = withHiddenAlert.alertsGroups.first { $0.workspaceID == "ws-hidden" }
        #expect(hiddenGroup?.isFromHiddenWorkspace == true)
    }
}
