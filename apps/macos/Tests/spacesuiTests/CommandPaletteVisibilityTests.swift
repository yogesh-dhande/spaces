import Testing
import workspacecore

@testable import spacesui

@Suite struct CommandPaletteVisibilityTests {
    private func makeItem(
        id: String, source: CommandPaletteItem.Source, workspaceID: String, kind: AppKitController.WorkspaceRunShortcutTarget.Kind, label: String,
        detail: String?, focusRequest: AppKitController.WindowFocusRequest, alertsAttentionID: String? = nil, workspaceTitle: String? = nil,
        workspaceBranch: String? = "main", projectTitle: String = "Spaces", status: CommandPaletteItem.Status = .none
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            id: id, source: source, alertsAttentionID: alertsAttentionID, workspaceID: workspaceID, workspaceTitle: workspaceTitle ?? workspaceID,
            workspaceBranch: workspaceBranch, projectTitle: projectTitle, kind: kind, label: label, detail: detail, status: status,
            focusRequest: focusRequest, recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: focusRequest, detail: detail))
    }

    @Test func paletteContextPrefersPreviouslySelectedWorkspace() {
        let workspaceID = AppKitController.preferredWorkspaceIDForCommandPalette(
            selectedWorkspaceID: "workspace-selected", focusedTerminalSessionWorkspaceID: "workspace-terminal",
            focusedWindowWorkspaceID: "workspace-focused")

        #expect(workspaceID == "workspace-selected")
    }

    @Test func paletteContextPrefersFocusedTerminalWorkspaceBeforeFocusedWindowWorkspace() {
        let workspaceID = AppKitController.preferredWorkspaceIDForCommandPalette(
            selectedWorkspaceID: nil, focusedTerminalSessionWorkspaceID: "workspace-terminal", focusedWindowWorkspaceID: "workspace-focused")

        #expect(workspaceID == "workspace-terminal")
    }

    @Test func paletteContextFallsBackToFocusedTrackedWorkspace() {
        let workspaceID = AppKitController.preferredWorkspaceIDForCommandPalette(
            selectedWorkspaceID: nil, focusedTerminalSessionWorkspaceID: nil, focusedWindowWorkspaceID: "workspace-focused")

        #expect(workspaceID == "workspace-focused")
    }

    @Test func emptyQueryShowsAlertsThenRecentTargetsAcrossWorkspaces() {
        let alertsItem = makeItem(
            id: "alerts::attention", source: .alertsAttention, workspaceID: "workspace-a", kind: .process, label: "Frontend", detail: "bun dev",
            focusRequest: .workspaceProcess(workspaceID: "workspace-a", processID: "proc-1"), alertsAttentionID: "attention-1",
            workspaceTitle: "Workspace A", status: .process(.exited))
        let currentWorkspaceItem = makeItem(
            id: "workspace-a::0", source: .workspaceTarget, workspaceID: "workspace-a", kind: .browser, label: "Docs",
            detail: "http://localhost:3000/docs",
            focusRequest: .workspaceBrowserSession(workspaceID: "workspace-a", targetURL: "http://localhost:3000/docs"), workspaceTitle: "Workspace A"
        )
        let otherWorkspaceItem = makeItem(
            id: "workspace-b::0", source: .workspaceTarget, workspaceID: "workspace-b", kind: .browser, label: "Admin",
            detail: "http://localhost:4000", focusRequest: .workspaceBrowserSession(workspaceID: "workspace-b", targetURL: "http://localhost:4000"),
            workspaceTitle: "Workspace B", workspaceBranch: "release")

        let visible = AppKitController.visibleCommandPaletteItems(
            allItems: [alertsItem, currentWorkspaceItem, otherWorkspaceItem], query: "", currentWorkspaceID: "workspace-a",
            recentFocusIdentities: [otherWorkspaceItem.recentFocusIdentity, currentWorkspaceItem.recentFocusIdentity])

        #expect(visible.map(\.id) == ["alerts::attention", "workspace-b::0", "workspace-a::0"])
    }

    @Test func emptyQueryPrefersAlertsWhenWorkspaceRowHasSameVisibleTarget() {
        let alertsItem = makeItem(
            id: "alerts::frontend", source: .alertsAttention, workspaceID: "workspace-a", kind: .process, label: "Frontend", detail: "bun dev",
            focusRequest: .workspaceProcess(workspaceID: "workspace-a", processID: "proc-alert"), alertsAttentionID: "attention-frontend",
            workspaceTitle: "Workspace A", status: .process(.exited))
        let workspaceItem = makeItem(
            id: "workspace-a::frontend", source: .workspaceTarget, workspaceID: "workspace-a", kind: .process, label: "Frontend", detail: "bun dev",
            focusRequest: .workspaceProcess(workspaceID: "workspace-a", processID: "proc-live"), workspaceTitle: "Workspace A",
            status: .process(.running))

        let visible = AppKitController.visibleCommandPaletteItems(
            allItems: [alertsItem, workspaceItem], query: "", currentWorkspaceID: "workspace-a", recentFocusIdentities: [])

        #expect(visible.map(\.id) == ["alerts::frontend"])
    }

    @Test func emptyQueryWithoutCurrentWorkspaceStillShowsRecentTargets() {
        let alertsItem = makeItem(
            id: "alerts::attention", source: .alertsAttention, workspaceID: "workspace-a", kind: .agent, label: "Claude", detail: nil,
            focusRequest: .agentWindow(
                .init(
                    id: "agent-1", workspaceID: "workspace-a", provider: .spaces, label: "Claude", terminalTrackingID: nil, sessionKey: nil,
                    status: .waiting, createdAt: "2026-04-30T00:00:00Z", updatedAt: "2026-04-30T00:00:00Z")), alertsAttentionID: "attention-2",
            workspaceTitle: "Workspace A", status: .agent(.waiting))
        let workspaceItem = makeItem(
            id: "workspace-a::0", source: .workspaceTarget, workspaceID: "workspace-a", kind: .process, label: "Frontend", detail: "bun dev",
            focusRequest: .workspaceProcess(workspaceID: "workspace-a", processID: "proc-1"), workspaceTitle: "Workspace A",
            status: .process(.running))

        let visible = AppKitController.visibleCommandPaletteItems(
            allItems: [alertsItem, workspaceItem], query: "", currentWorkspaceID: nil, recentFocusIdentities: [workspaceItem.recentFocusIdentity])

        #expect(visible.map(\.id) == ["alerts::attention", "workspace-a::0"])
    }

    @Test func emptyQueryCapsVisibleItemsToNine() {
        let alertsItem = makeItem(
            id: "alerts::attention", source: .alertsAttention, workspaceID: "workspace-a", kind: .process, label: "Frontend", detail: "bun dev",
            focusRequest: .workspaceProcess(workspaceID: "workspace-a", processID: "proc-1"), alertsAttentionID: "attention-1",
            workspaceTitle: "Workspace A")
        let workspaceItems = (1...10).map { index in
            makeItem(
                id: "workspace-\(index)", source: .workspaceTarget, workspaceID: "workspace-\(index)", kind: .browser, label: "Target \(index)",
                detail: "http://localhost:\(3000 + index)",
                focusRequest: .workspaceBrowserSession(workspaceID: "workspace-\(index)", targetURL: "http://localhost:\(3000 + index)"))
        }

        let visible = AppKitController.visibleCommandPaletteItems(
            allItems: [alertsItem] + workspaceItems, query: "", currentWorkspaceID: nil,
            recentFocusIdentities: workspaceItems.reversed().map(\.recentFocusIdentity))

        #expect(visible.count == 9)
        #expect(visible.first?.id == "alerts::attention")
    }

    @Test func emptyQueryCapsAlertsOnlyListToNine() {
        let alertItems = (1...12).map { index in
            makeItem(
                id: "alerts::\(index)", source: .alertsAttention, workspaceID: "workspace-\(index)", kind: .process, label: "Alert \(index)",
                detail: "command \(index)", focusRequest: .workspaceProcess(workspaceID: "workspace-\(index)", processID: "proc-\(index)"),
                alertsAttentionID: "attention-\(index)")
        }

        let visible = AppKitController.visibleCommandPaletteItems(allItems: alertItems, query: "", currentWorkspaceID: nil, recentFocusIdentities: [])

        #expect(visible.count == 9)
        #expect(visible.map(\.id) == Array((1...9).map { "alerts::\($0)" }))
    }

    /// Picker rows all carry the same placeholder focus request, so the normal
    /// palette's focus-identity dedup would collapse them to one row; the picker's
    /// empty query must instead show the host-ordered list head (up to ten rows).
    @Test func sessionPickerEmptyQueryShowsFirstTenRows() {
        let items = (0...11).map { index in
            makeItem(
                id: "picker:\(index)", source: .workspaceTarget, workspaceID: "workspace-a", kind: .window,
                label: index == 0 ? "New terminal session" : "session-\(index)", detail: nil,
                focusRequest: .workspaceWindow(workspaceID: "workspace-a", index: 1))
        }

        let visible = AppKitController.visibleSessionPickerItems(allItems: items, query: "")

        #expect(visible.map(\.id) == (0...9).map { "picker:\($0)" })
    }

    @Test func sessionPickerQuerySearchesAllRowsAcrossWorkspaces() {
        let items = (1...15).map { index in
            makeItem(
                id: "picker:\(index)", source: .workspaceTarget, workspaceID: "workspace-\(index)", kind: .window, label: "session-\(index)",
                detail: nil, focusRequest: .workspaceWindow(workspaceID: "workspace-\(index)", index: 1),
                workspaceTitle: "Workspace \(index)")
        }

        let visible = AppKitController.visibleSessionPickerItems(allItems: items, query: "session-15")

        #expect(visible.first?.id == "picker:15")
    }

    @Test func searchQueryUsesAllWorkspaceItems() {
        let workspaceItem = makeItem(
            id: "workspace-b::0", source: .workspaceTarget, workspaceID: "workspace-b", kind: .browser, label: "URL", detail: "http://localhost:4000",
            focusRequest: .workspaceBrowserSession(workspaceID: "workspace-b", targetURL: "http://localhost:4000"), workspaceTitle: "Frontend",
            workspaceBranch: "feature/url")

        let visible = AppKitController.visibleCommandPaletteItems(
            allItems: [workspaceItem], query: "fu", currentWorkspaceID: nil, recentFocusIdentities: [])

        #expect(visible.map(\.id) == ["workspace-b::0"])
    }
}
