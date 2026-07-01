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
        id: String, isRunning: Bool = true, isArchived: Bool = false,
        processRows: [SpacesDeviceWorkspaceProcessRow] = [], codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = []
    ) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main",
            dir: "/device/\(id)", isRunning: isRunning, isArchived: isArchived, isHidden: false, isDefault: false, notes: nil, sessionCount: 0,
            assignedPorts: [], setupState: nil, config: SpacesDeviceWorkspaceConfig(), processRows: processRows, codingAgentRows: codingAgentRows,
            terminalRows: [])
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

    private func agent(
        id: String, agentID: String?, activityState: SpacesDeviceCodingAgentActivityState, updatedAt: String?
    ) -> SpacesDeviceWorkspaceCodingAgentRow {
        SpacesDeviceWorkspaceCodingAgentRow(
            id: id, workspaceID: "ws", name: "Codex", command: "codex", launcherID: id, agentID: agentID, sessionID: nil, isConfigured: true,
            runState: .running, activityState: activityState, updatedAt: updatedAt, canRun: false, canStop: true, canRestart: true)
    }

    private func overview(_ workspaces: [SpacesDeviceWorkspaceSummary]) -> SpacesDeviceOverviewPayload {
        SpacesDeviceOverviewPayload(projects: [], workspaces: workspaces, sessions: [])
    }

    @Test func exitedProcessOnRunningWorkspaceProducesProcessAlert() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview([
                workspace(id: "ws", processRows: [exitedProcess(id: "p1", processID: "run-1", exitedAt: "2026-06-28T10:00:00Z"), runningProcess(id: "p2")])
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
    }

    @Test func exitedProcessOnStoppedWorkspaceIsIgnored() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isRunning: false, processRows: [exitedProcess(id: "p1", processID: "run-1", exitedAt: "t")])]),
            deviceID: "local")
        #expect(groups.isEmpty)
    }

    @Test func archivedWorkspaceIsExcluded() {
        let groups = AppKitController.buildOverviewAlertsGroups(
            from: overview([workspace(id: "ws", isArchived: true, codingAgentRows: [agent(id: "a", agentID: "ag", activityState: .waiting, updatedAt: nil)])]),
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
            groups[0].items.map(\.attentionID) == [
                "alert:local:process:new:2026-06-28T12:00:00Z", "alert:local:process:old:2026-06-28T08:00:00Z",
            ])
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
}
