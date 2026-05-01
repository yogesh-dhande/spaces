import Testing
import workspacecore

@testable import spacesui

@Suite struct CommandPaletteVisibilityTests {
    @Test func paletteContextPrefersPreviouslySelectedWorkspace() {
        let workspaceID = AppKitController.commandPaletteContextWorkspaceID(
            selectedWorkspaceID: "workspace-selected", focusedWorkspaceID: { "workspace-focused" })

        #expect(workspaceID == "workspace-selected")
    }

    @Test func paletteContextSkipsFocusedWorkspaceLookupWhenSelectionExists() throws {
        enum SentinelError: Error { case shouldNotBeCalled }

        let workspaceID = try AppKitController.commandPaletteContextWorkspaceID(selectedWorkspaceID: "workspace-selected") {
            throw SentinelError.shouldNotBeCalled
        }

        #expect(workspaceID == "workspace-selected")
    }

    @Test func paletteContextFallsBackToFocusedTrackedWorkspace() {
        let workspaceID = AppKitController.commandPaletteContextWorkspaceID(selectedWorkspaceID: nil, focusedWorkspaceID: { "workspace-focused" })

        #expect(workspaceID == "workspace-focused")
    }

    @Test func emptyQueryShowsAlertsThenCurrentWorkspaceItemsOnly() {
        let alertsItem = CommandPaletteItem(
            id: "alerts::attention", source: .alertsAttention, alertsAttentionID: "attention-1", workspaceID: "workspace-a",
            workspaceTitle: "Workspace A", workspaceBranch: "main", projectTitle: "Muxy", kind: .process, label: "Frontend", detail: "bun dev",
            status: .process(.exited), focusRequest: .workspaceProcess(workspaceID: "workspace-a", processID: "proc-1"))
        let currentWorkspaceItem = CommandPaletteItem(
            id: "workspace-a::0", source: .workspaceTarget, alertsAttentionID: nil, workspaceID: "workspace-a", workspaceTitle: "Workspace A",
            workspaceBranch: "main", projectTitle: "Muxy", kind: .browser, label: "Docs", detail: "http://localhost:3000/docs", status: .none,
            focusRequest: .workspaceBrowserSession(workspaceID: "workspace-a", targetURL: "http://localhost:3000/docs"))
        let otherWorkspaceItem = CommandPaletteItem(
            id: "workspace-b::0", source: .workspaceTarget, alertsAttentionID: nil, workspaceID: "workspace-b", workspaceTitle: "Workspace B",
            workspaceBranch: "release", projectTitle: "Muxy", kind: .browser, label: "Admin", detail: "http://localhost:4000", status: .none,
            focusRequest: .workspaceBrowserSession(workspaceID: "workspace-b", targetURL: "http://localhost:4000"))

        let visible = AppKitController.visibleCommandPaletteItems(
            allItems: [alertsItem, currentWorkspaceItem, otherWorkspaceItem], query: "", currentWorkspaceID: "workspace-a")

        #expect(visible.map(\.id) == ["alerts::attention", "workspace-a::0"])
    }

    @Test func emptyQueryPrefersAlertsWhenWorkspaceRowHasSameVisibleTarget() {
        let alertsItem = CommandPaletteItem(
            id: "alerts::frontend", source: .alertsAttention, alertsAttentionID: "attention-frontend", workspaceID: "workspace-a",
            workspaceTitle: "Workspace A", workspaceBranch: "main", projectTitle: "Muxy", kind: .process, label: "Frontend", detail: "bun dev",
            status: .process(.exited), focusRequest: .workspaceProcess(workspaceID: "workspace-a", processID: "proc-alert"))
        let workspaceItem = CommandPaletteItem(
            id: "workspace-a::frontend", source: .workspaceTarget, alertsAttentionID: nil, workspaceID: "workspace-a", workspaceTitle: "Workspace A",
            workspaceBranch: "main", projectTitle: "Muxy", kind: .process, label: "Frontend", detail: "bun dev", status: .process(.running),
            focusRequest: .workspaceProcess(workspaceID: "workspace-a", processID: "proc-live"))

        let visible = AppKitController.visibleCommandPaletteItems(
            allItems: [alertsItem, workspaceItem], query: "", currentWorkspaceID: "workspace-a")

        #expect(visible.map(\.id) == ["alerts::frontend"])
    }

    @Test func emptyQueryWithoutCurrentWorkspaceShowsAlertsOnly() {
        let alertsItem = CommandPaletteItem(
            id: "alerts::attention", source: .alertsAttention, alertsAttentionID: "attention-2", workspaceID: "workspace-a",
            workspaceTitle: "Workspace A", workspaceBranch: "main", projectTitle: "Muxy", kind: .agent, label: "Claude", detail: nil,
            status: .agent(.waiting),
            focusRequest: .agentWindow(
                .init(
                    id: "agent-1", workspaceID: "workspace-a", provider: .ghostty, label: "Claude", terminalTrackingID: nil, codexThreadID: nil,
                    windowID: nil, yabaiWindowID: nil, status: .waiting, createdAt: "2026-04-30T00:00:00Z", updatedAt: "2026-04-30T00:00:00Z")))
        let workspaceItem = CommandPaletteItem(
            id: "workspace-a::0", source: .workspaceTarget, alertsAttentionID: nil, workspaceID: "workspace-a", workspaceTitle: "Workspace A",
            workspaceBranch: "main", projectTitle: "Muxy", kind: .process, label: "Frontend", detail: "bun dev", status: .process(.running),
            focusRequest: .workspaceProcess(workspaceID: "workspace-a", processID: "proc-1"))

        let visible = AppKitController.visibleCommandPaletteItems(allItems: [alertsItem, workspaceItem], query: "", currentWorkspaceID: nil)

        #expect(visible.map(\.id) == ["alerts::attention"])
    }

    @Test func searchQueryUsesAllWorkspaceItems() {
        let workspaceItem = CommandPaletteItem(
            id: "workspace-b::0", source: .workspaceTarget, alertsAttentionID: nil, workspaceID: "workspace-b", workspaceTitle: "Frontend",
            workspaceBranch: "feature/url", projectTitle: "Muxy", kind: .browser, label: "URL", detail: "http://localhost:4000", status: .none,
            focusRequest: .workspaceBrowserSession(workspaceID: "workspace-b", targetURL: "http://localhost:4000"))

        let visible = AppKitController.visibleCommandPaletteItems(allItems: [workspaceItem], query: "fu", currentWorkspaceID: nil)

        #expect(visible.map(\.id) == ["workspace-b::0"])
    }
}
